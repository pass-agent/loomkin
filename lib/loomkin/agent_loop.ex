defmodule Loomkin.AgentLoop do
  @moduledoc """
  Reusable ReAct agent loop. Used by both Loomkin.Session and Loomkin.Teams.Agent.

  The loop is parameterized via callbacks so callers can control persistence,
  event broadcasting, and permission handling without coupling to any specific
  GenServer or PubSub topology.
  """

  alias Loomkin.AgentLoop.Checkpoint
  alias Loomkin.Healing.ErrorClassifier
  alias Loomkin.Permissions.HookRunner
  alias Loomkin.Session.ContextWindow
  alias Loomkin.Teams.ContextOffload
  alias Loomkin.Security.Redactor
  alias Loomkin.Telemetry, as: LoomkinTelemetry

  require Logger

  @default_max_rate_limit_retries 3
  @default_max_iterations 30

  @type on_event :: (atom(), map() -> :ok)

  @doc """
  Run a ReAct agent loop.

  ## Options

    * `:model` - LLM model string (e.g. "anthropic:claude-sonnet-4-6"). Required.
    * `:tools` - list of tool action modules. Default `[]`.
    * `:system_prompt` - the system prompt string. Required.
    * `:project_path` - path to the project being worked on.
    * `:session_id` - session identifier (used for context window enrichment).
    * `:on_event` - `fn event_name, payload -> :ok end` callback for streaming events.
    * `:on_tool_execute` - `fn tool_module, tool_args, context -> result_text` override.
       When not provided, tools are executed via `Jido.Exec.run/4`.
    * `:check_permission` - `fn tool_name, tool_path -> :allowed | {:pending, pending_data}`.
       When not provided, all tools are allowed.
    * `:checkpoint` - `fn(%Checkpoint{}) -> :continue | {:pause, reason}`.
       Called after LLM response (before tool execution) and after each tool execution.
       When not provided or nil, execution proceeds without pausing.

  Returns `{:ok, response_text, messages, metadata}`, `{:error, reason, messages}`,
  `{:pending_permission, pending_info, messages}`, or
  `{:paused, reason, messages, iteration}`.

  The `messages` list returned always includes the full updated conversation
  (input messages + new assistant/tool messages from the loop), so the caller
  can persist or discard them as needed.
  """
  @spec run([map()], keyword()) ::
          {:ok, String.t(), [map()], map()}
          | {:error, term(), [map()]}
          | {:pending_permission, map(), [map()]}
          | {:paused, term(), [map()], non_neg_integer()}
  def run(messages, opts) do
    config = build_config(opts)
    # Initialize read-file tracker for read-before-write enforcement
    Process.put(:loomkin_read_files, MapSet.new())
    # Initialize cycle detection tracker (previous tool-call signature)
    Process.put(:loomkin_prev_tool_signature, nil)

    # Bootstrap failure memory: inject lessons from past errors
    messages = bootstrap_failure_memory(messages, config)

    case config.reasoning_strategy do
      :react ->
        run_with_rate_limit_retry(messages, config, 0)

      strategy when strategy in [:cot, :cod, :tot, :adaptive] ->
        Loomkin.AgentLoop.Strategies.run(strategy, messages, config)

      _unknown ->
        run_with_rate_limit_retry(messages, config, 0)
    end
  end

  defp run_with_rate_limit_retry(messages, config, attempt) do
    try do
      do_loop(messages, config, 0)
    catch
      {:budget_exceeded, scope} ->
        emit(config, :budget_exceeded, %{
          scope: scope,
          agent_name: config.agent_name,
          team_id: config.team_id
        })

        error_msg = "Budget exceeded (#{scope}). Stopping agent loop."
        {:error, error_msg, messages}

      {:rate_limited, provider} ->
        if attempt < max_rate_limit_retries() do
          backoff_ms = Integer.pow(2, attempt) * 1_000

          config.on_event.(:rate_limited, %{
            provider: provider,
            retry: attempt + 1,
            backoff_ms: backoff_ms
          })

          Process.sleep(backoff_ms)
          run_with_rate_limit_retry(messages, config, attempt + 1)
        else
          {:error, :rate_limited, messages}
        end
    end
  end

  # -- Config ------------------------------------------------------------------

  defp build_config(opts) do
    %{
      model: Keyword.fetch!(opts, :model),
      tools: Keyword.get(opts, :tools, []),
      role: Keyword.get(opts, :role),
      system_prompt: Keyword.fetch!(opts, :system_prompt),
      project_path: Keyword.get(opts, :project_path),
      project_path_resolver: Keyword.get(opts, :project_path_resolver),
      session_id: Keyword.get(opts, :session_id),
      user: Keyword.get(opts, :user),
      agent_name: Keyword.get(opts, :agent_name),
      team_id: Keyword.get(opts, :team_id),
      reasoning_strategy: Keyword.get(opts, :reasoning_strategy, :react),
      max_iterations: Keyword.get(opts, :max_iterations, max_iterations()),
      on_event: Keyword.get(opts, :on_event, fn _name, _payload -> :ok end),
      on_tool_execute: Keyword.get(opts, :on_tool_execute),
      check_permission: Keyword.get(opts, :check_permission),
      checkpoint: Keyword.get(opts, :checkpoint),
      rate_limiter: Keyword.get(opts, :rate_limiter)
    }
  end

  defp max_iterations do
    Loomkin.Config.get(:agents, :max_iterations) || @default_max_iterations
  end

  defp max_rate_limit_retries do
    Loomkin.Config.get(:agents, :max_rate_limit_retries) || @default_max_rate_limit_retries
  end

  @doc """
  Returns the current project path, preferring the dynamic resolver over
  the static value captured at loop-spawn time.
  """
  def current_project_path(config) do
    case config[:project_path_resolver] do
      resolver when is_function(resolver, 0) ->
        resolver.() || config.project_path

      _ ->
        config.project_path
    end
  end

  # -- Loop --------------------------------------------------------------------

  defp do_loop(messages, %{max_iterations: max} = config, iteration)
       when iteration >= max do
    error_msg =
      "Agent exceeded maximum iterations (#{max}). " <>
        "Stopping to avoid infinite loops."

    emit(config, :max_iterations_exceeded, %{iterations: iteration, max: max})

    # Return the error as an assistant message so the user sees it
    assistant_msg = %{role: :assistant, content: error_msg}
    messages = messages ++ [assistant_msg]
    emit(config, :new_message, assistant_msg)

    {:ok, error_msg, messages, %{usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0}}}
  end

  defp do_loop(messages, config, iteration) do
    # Auto-offload context if agent is above threshold
    messages = maybe_auto_offload(messages, config)

    # Build windowed messages with context enrichment (use dynamic path)
    effective_project_path = current_project_path(config)

    windowed =
      ContextWindow.build_messages(messages, config.system_prompt,
        model: config.model,
        session_id: config.session_id,
        project_path: effective_project_path,
        team_id: config[:team_id],
        user: config[:user]
      )

    # Parse model and build req_llm messages
    {provider, model_id} = parse_model(config.model)
    req_messages = build_req_messages(windowed)

    # Build tool definitions for the LLM
    tool_defs = build_tool_definitions(config.tools)
    opts = if tool_defs != [], do: [tools: tool_defs], else: []

    # Check rate limiter / budget before calling LLM
    case maybe_acquire_rate_limit(config, provider) do
      :ok ->
        :ok

      {:wait, ms} ->
        Process.sleep(min(ms, 5_000))

        # Re-acquire after waiting — must get a successful reservation
        case maybe_acquire_rate_limit(config, provider) do
          :ok -> :ok
          {:wait, _} -> throw({:rate_limited, provider})
          {:budget_exceeded, scope} -> throw({:budget_exceeded, scope})
        end

      {:budget_exceeded, scope} ->
        throw({:budget_exceeded, scope})
    end

    telemetry_meta = %{
      session_id: config.session_id,
      model: config.model,
      iteration: iteration
    }

    on_retry = fn attempt, reason, backoff_ms ->
      emit(config, :llm_retry, %{
        attempt: attempt,
        reason: inspect(reason),
        backoff_ms: backoff_ms
      })
    end

    case Loomkin.LLMRetry.with_retry([on_retry: on_retry], fn ->
           LoomkinTelemetry.span_llm_request(telemetry_meta, fn ->
             call_llm(provider, model_id, req_messages, [{:stream_config, config} | opts])
           end)
         end) do
      {:ok, response} ->
        classified = ReqLLM.Response.classify(response)
        handle_classified(classified, response, messages, config, iteration)

      {:error, reason} ->
        Logger.error("[Kin:llm] call failed model=#{config.model} reason=#{inspect(reason)}")
        {:error, reason, messages}
    end
  end

  # -- Response handling -------------------------------------------------------

  defp handle_classified(
         %{type: :tool_calls} = classified,
         response,
         messages,
         config,
         iteration
       ) do
    emit(config, :tool_calls_received, %{
      tool_calls: classified.tool_calls,
      text: classified.text
    })

    # Build assistant message with tool calls
    assistant_msg = %{
      role: :assistant,
      content: classified.text,
      tool_calls: classified.tool_calls
    }

    messages = messages ++ [assistant_msg]
    emit(config, :new_message, assistant_msg)

    # Post-LLM checkpoint — let the observer see planned tools before execution
    checkpoint = %Checkpoint{
      type: :post_llm,
      agent_name: config.agent_name,
      team_id: config.team_id,
      iteration: iteration,
      planned_tools: classified.tool_calls,
      messages: messages
    }

    case maybe_checkpoint(config, checkpoint) do
      :continue ->
        # Execute tool calls
        case execute_tool_calls(classified.tool_calls, messages, config, iteration) do
          {:ok, messages} ->
            emit_usage(config, response)
            messages = maybe_inject_cycle_warning(classified.tool_calls, messages, config)
            do_loop(messages, config, iteration + 1)

          {:paused, reason, messages} ->
            emit_usage(config, response)
            {:paused, reason, messages, iteration}

          {:pending, remaining_tool_calls, messages, pending_data} ->
            # Permission system paused the loop — return control to caller
            pending_info = %{
              remaining_tool_calls: remaining_tool_calls,
              response: response,
              iteration: iteration,
              config: config,
              pending_data: pending_data
            }

            {:pending_permission, pending_info, messages}
        end

      {:pause, reason} ->
        emit_usage(config, response)
        {:paused, reason, messages, iteration}
    end
  end

  defp handle_classified(
         %{type: :final_answer} = classified,
         response,
         messages,
         config,
         _iteration
       ) do
    response_text = classified.text

    assistant_msg = %{role: :assistant, content: response_text}
    messages = messages ++ [assistant_msg]
    emit(config, :new_message, assistant_msg)

    usage = extract_usage(response)
    emit_usage(config, response)

    {:ok, response_text, messages, %{usage: usage}}
  end

  # -- Tool execution ----------------------------------------------------------

  defp execute_tool_calls(tool_calls, messages, config) do
    execute_tool_calls(tool_calls, messages, config, 0)
  end

  defp execute_tool_calls([], messages, _config, _iteration), do: {:ok, messages}

  defp execute_tool_calls([tool_call | rest], messages, config, iteration) do
    case execute_single_tool(tool_call, messages, config, iteration) do
      {:ok, messages} ->
        execute_tool_calls(rest, messages, config, iteration)

      {:paused, reason, messages} ->
        {:paused, reason, messages}

      {:pending, pending_data, messages} ->
        {:pending, rest, messages, pending_data}
    end
  end

  defp execute_single_tool(tool_call, messages, config, iteration) do
    tool_name = tool_call[:name]
    tool_args = tool_call[:arguments] || %{}
    tool_call_id = tool_call[:id] || "call_#{Ecto.UUID.generate()}"

    if is_nil(tool_name) do
      Logger.warning("[Kin:data] nil tool_name in tool_call: #{inspect(tool_call, limit: 200)}")
    end

    tool_path = tool_args["file_path"] || tool_args["path"] || "*"

    # Dynamically resolve project_path at each tool execution
    effective_path = current_project_path(config)

    # For team_spawn: if this agent is in a root team, use its own team_id as parent
    # so sub-teams are created under it (not as standalone teams)
    parent_team_id =
      case Loomkin.Teams.Manager.get_parent_team(config.team_id) do
        {:ok, parent_id} -> parent_id
        :error -> config.team_id
      end

    context = %{
      project_path: effective_path,
      session_id: config.session_id,
      agent_name: config.agent_name,
      team_id: config.team_id,
      parent_team_id: parent_team_id,
      model: config.model
    }

    emit(config, :tool_executing, %{tool_name: tool_name, tool_target: tool_path})

    case Jido.AI.ToolAdapter.lookup_action(tool_name, config.tools) do
      {:error, :not_found} ->
        result_text = "Error: Tool '#{tool_name}' not found"
        messages = record_tool_result(messages, config, tool_name, tool_call_id, result_text)
        {:ok, messages}

      {:ok, tool_module} ->
        # Role-based tool filtering: reject tools not allowed for this role
        role_allowed =
          case config.role do
            nil -> true
            role -> Loomkin.Tools.ToolFilter.allowed?(role, tool_module)
          end

        if not role_allowed do
          reason = Loomkin.Tools.ToolFilter.denial_reason(config.role, tool_module)

          Logger.warning(
            "[Kin:tool_filter] Blocked tool=#{tool_name} for role=#{config.role}: #{reason}"
          )

          result_text =
            "Error: Tool '#{tool_name}' is not available for your role (#{config.role}). #{reason} " <>
              "Do NOT attempt clever workarounds to bypass this restriction. " <>
              "Your team depends on role specialization — ask for help instead. " <>
              "If you know which teammate can handle this, use peer_message to ask them directly. " <>
              "Otherwise, use peer_message to ask the concierge — they will spawn the right specialist for what you need. " <>
              "Describe exactly what you need done and why."

          messages = record_tool_result(messages, config, tool_name, tool_call_id, result_text)
          {:ok, messages}
        else
          # Check permissions if a check_permission callback is provided
          permission_result =
            if config.check_permission do
              config.check_permission.(tool_name, tool_path)
            else
              :allowed
            end

          case permission_result do
            :allowed ->
              # Tag context for permitted external reads so file_read can bypass safe_path!
              context =
                if effective_path &&
                     Loomkin.Tool.outside_project?(
                       Loomkin.Tool.resolve_path(tool_path, effective_path),
                       effective_path
                     ) do
                  Map.put(
                    context,
                    :allowed_external_path,
                    Loomkin.Tool.resolve_path(tool_path, effective_path)
                  )
                else
                  context
                end

              # Pass read_files set to tools for read-before-write enforcement
              read_files = Process.get(:loomkin_read_files, MapSet.new())
              context = Map.put(context, :read_files, read_files)

              # Set project path in process dictionary for hook modules
              Process.put(:loomkin_project_path, effective_path)

              # Load hooks once for both pre and post phases
              pre_hooks = HookRunner.load_hooks(:pre_tool)
              post_hooks = HookRunner.load_hooks(:post_tool)

              case HookRunner.run_pre_hooks(pre_hooks, tool_name, tool_args) do
                :deny ->
                  Logger.warning("[Kin:hook] pre-hook denied tool=#{tool_name}")
                  result_text = "Error: Tool '#{tool_name}' blocked by pre-tool hook"

                  messages =
                    record_tool_result(messages, config, tool_name, tool_call_id, result_text)

                  {:ok, messages}

                {:ask, reason} ->
                  Logger.info(
                    "[Kin:hook] pre-hook asked confirmation tool=#{tool_name} reason=#{reason}"
                  )

                  result_text = "Tool '#{tool_name}' requires confirmation: #{reason}"

                  messages =
                    record_tool_result(messages, config, tool_name, tool_call_id, result_text)

                  {:ok, messages}

                :allow ->
                  raw_result = run_tool(tool_module, tool_args, context, config)

                  result_text =
                    case HookRunner.run_post_hooks(post_hooks, tool_name, tool_args, raw_result) do
                      {:rollback, reason} ->
                        raw_result <> "\n\nWarning: post-tool hook flagged: #{reason}"

                      :ok ->
                        raw_result
                    end

                  # Track successful file_read calls
                  maybe_track_read_file(tool_name, tool_args, effective_path, result_text)

                  messages =
                    record_tool_result(messages, config, tool_name, tool_call_id, result_text)

                  # Post-tool checkpoint — let the observer see the result
                  post_tool_checkpoint = %Checkpoint{
                    type: :post_tool,
                    agent_name: config.agent_name,
                    team_id: config.team_id,
                    iteration: iteration,
                    tool_name: tool_name,
                    tool_result: result_text,
                    messages: messages
                  }

                  case maybe_checkpoint(config, post_tool_checkpoint) do
                    :continue -> {:ok, messages}
                    {:pause, reason} -> {:paused, reason, messages}
                  end
              end

            {:pending, pending_data} ->
              pending =
                Map.merge(pending_data, %{
                  tool_call: tool_call,
                  tool_module: tool_module,
                  tool_name: tool_name,
                  tool_path: tool_path,
                  tool_call_id: tool_call_id,
                  tool_args: tool_args,
                  context: context
                })

              {:pending, pending, messages}
          end
        end
    end
  end

  defp run_tool(tool_module, tool_args, context, config) do
    result =
      if config.on_tool_execute do
        config.on_tool_execute.(tool_module, tool_args, context)
      else
        default_run_tool(tool_module, tool_args, context)
      end

    # Ensure we always return a string — custom on_tool_execute callbacks
    # may return raw Jido tuples like {:ok, %{result: "..."}}
    if is_binary(result), do: result, else: format_tool_result(result)
  end

  @doc false
  def default_run_tool(tool_module, tool_args, context) do
    tool_meta = %{
      tool_name: tool_module |> Module.split() |> List.last() |> Macro.underscore(),
      session_id: context[:session_id]
    }

    # LLM tool calls arrive with string keys ("pattern") but Jido schema
    # validation expects atom keys (:pattern). Atomize known keys safely.
    atomized_args = atomize_known_keys(tool_args, tool_module)

    # Auto-inject team_id from context when the tool requires it but the LLM
    # didn't include it in the call (common with background agents).
    atomized_args =
      if not Map.has_key?(atomized_args, :team_id) and context[:team_id] do
        Map.put(atomized_args, :team_id, context[:team_id])
      else
        atomized_args
      end

    tool_type = String.to_atom(tool_meta.tool_name)

    result =
      case Loomkin.Tools.RunnerRegistry.acquire(tool_type) do
        :ok ->
          try do
            LoomkinTelemetry.span_tool_execute(tool_meta, fn ->
              try do
                Jido.Exec.run(tool_module, atomized_args, context, timeout: 60_000)
              rescue
                e ->
                  Logger.error(
                    "[Kin:tool] #{tool_meta.tool_name} raised: #{Exception.message(e)}\n" <>
                      Exception.format_stacktrace(__STACKTRACE__)
                  )

                  {:error, Exception.message(e)}
              end
            end)
          after
            Loomkin.Tools.RunnerRegistry.release(tool_type)
          end

        {:error, :concurrency_limit} ->
          {:error,
           "Tool #{tool_meta.tool_name} rejected: concurrency limit reached. Try again shortly."}
      end

    format_tool_result(result)
  end

  defp atomize_known_keys(args, tool_module) do
    known_keys =
      try do
        Jido.Action.Schema.known_keys(tool_module.schema())
      rescue
        _ -> []
      end

    known_strings = Map.new(known_keys, fn k -> {Atom.to_string(k), k} end)

    Map.new(args, fn
      {k, v} when is_binary(k) ->
        case Map.fetch(known_strings, k) do
          {:ok, atom_key} -> {atom_key, deep_atomize_value(v)}
          :error -> {k, deep_atomize_value(v)}
        end

      {k, v} ->
        {k, deep_atomize_value(v)}
    end)
  end

  # Recursively atomize string keys in nested maps and lists.
  # LLM tool calls return JSON with string keys at every nesting level,
  # but Jido/NimbleOptions validation expects atom keys for maps.
  defp deep_atomize_value(list) when is_list(list) do
    Enum.map(list, &deep_atomize_value/1)
  end

  defp deep_atomize_value(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> k
          end

        {atom_key, deep_atomize_value(v)}

      {k, v} ->
        {k, deep_atomize_value(v)}
    end)
  end

  defp deep_atomize_value(value), do: value

  defp record_tool_result(messages, config, tool_name, tool_call_id, result_text) do
    result_text =
      if is_nil(result_text) do
        Logger.warning("[Kin:data] nil tool_result for tool=#{tool_name}")
        ""
      else
        result_text
      end

    # Redact secrets before the result reaches PubSub, logs, or LLM context
    result_text = Redactor.redact(result_text)

    emit(config, :tool_complete, %{tool_name: tool_name, result: result_text})

    if String.starts_with?(result_text, "Error:") do
      emit(config, :tool_error, %{tool_name: tool_name, error: result_text})

      classification =
        ErrorClassifier.classify(result_text, %{tool_name: tool_name})

      emit(config, :tool_error_classified, %{
        tool_name: tool_name,
        classification: classification
      })

      maybe_record_failure_memory(config, tool_name, result_text, classification)
    end

    tool_msg = %{role: :tool, content: result_text, tool_call_id: tool_call_id}
    emit(config, :new_message, tool_msg)

    messages ++ [tool_msg]
  end

  # -- Checkpoint evaluation ----------------------------------------------------

  defp maybe_checkpoint(%{checkpoint: nil}, _checkpoint), do: :continue

  defp maybe_checkpoint(%{checkpoint: callback}, %Checkpoint{} = checkpoint)
       when is_function(callback, 1) do
    callback.(checkpoint)
  end

  defp maybe_checkpoint(_config, _checkpoint), do: :continue

  # -- Resume after permission -------------------------------------------------

  @doc """
  Resume the agent loop after a permission decision.

  Called by the owning process (e.g. Session) after the user responds to a
  permission prompt. `tool_result_text` is the result of executing (or denying)
  the pending tool.

  `pending_info` is the map returned in `{:pending_permission, pending_info, messages}`.
  """
  @spec resume(String.t(), map(), [map()]) ::
          {:ok, String.t(), [map()], map()}
          | {:error, term(), [map()]}
          | {:pending_permission, map(), [map()]}
          | {:paused, term(), [map()], non_neg_integer()}
  def resume(tool_result_text, pending_info, messages) do
    config = pending_info.config
    tool_call_id = pending_info.pending_data.tool_call_id
    tool_name = pending_info.pending_data.tool_name

    # Restore read-file tracker from pending context (may have been lost across process boundary)
    if read_files = get_in(pending_info, [:pending_data, :context, :read_files]) do
      Process.put(:loomkin_read_files, read_files)
    end

    # Record the tool result
    messages = record_tool_result(messages, config, tool_name, tool_call_id, tool_result_text)

    # Process remaining tool calls from the batch
    case execute_tool_calls(pending_info.remaining_tool_calls, messages, config) do
      {:ok, messages} ->
        emit_usage(config, pending_info.response)
        do_loop(messages, config, pending_info.iteration + 1)

      {:paused, reason, messages} ->
        {:paused, reason, messages, pending_info.iteration}

      {:pending, remaining, messages, new_pending_data} ->
        new_pending_info = %{
          remaining_tool_calls: remaining,
          response: pending_info.response,
          iteration: pending_info.iteration,
          config: config,
          pending_data: new_pending_data
        }

        {:pending_permission, new_pending_info, messages}
    end
  end

  # -- Read-file tracking (read-before-write enforcement) ----------------------

  defp maybe_track_read_file(tool_name, tool_args, project_path, result_text)
       when tool_name in ["file_read", :file_read] do
    # Only track successful reads (result doesn't start with "Error:")
    if result_text && not String.starts_with?(result_text, "Error:") do
      file_path = tool_args["file_path"] || tool_args[:file_path]

      if file_path && project_path do
        # Use safe_path! to canonicalize (resolve symlinks) — matches file_edit's path form
        full_path = Loomkin.Tool.safe_path!(file_path, project_path)
        read_files = Process.get(:loomkin_read_files, MapSet.new())
        Process.put(:loomkin_read_files, MapSet.put(read_files, full_path))
      end
    end
  rescue
    # safe_path! raises on paths outside the project — skip tracking
    ArgumentError -> :ok
  end

  defp maybe_track_read_file(_tool_name, _tool_args, _project_path, _result_text), do: :ok

  # -- Cycle detection ---------------------------------------------------------

  @cycle_warning "You already called the same tool(s) with identical arguments " <>
                   "in the previous iteration and got the same results. Do NOT repeat " <>
                   "the same calls. Either use the results you already have to form a " <>
                   "final answer, or try a different approach."

  defp maybe_inject_cycle_warning(tool_calls, messages, config) do
    prev_sig = Process.get(:loomkin_prev_tool_signature)
    current_sig = tool_call_signature(tool_calls)
    Process.put(:loomkin_prev_tool_signature, current_sig)

    if prev_sig == current_sig and prev_sig != nil do
      warning_msg = %{role: :user, content: @cycle_warning}
      emit(config, :cycle_detected, %{signature: current_sig})
      emit(config, :new_message, warning_msg)
      messages ++ [warning_msg]
    else
      messages
    end
  end

  defp tool_call_signature(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(fn tc ->
      name = tc[:name] || tc["name"] || ""
      args = tc[:arguments] || tc["arguments"] || %{}
      "#{name}:#{inspect(args)}"
    end)
    |> Enum.sort()
    |> Enum.join("|")
  end

  # -- Helpers -----------------------------------------------------------------

  @doc false
  def format_tool_result(result) do
    text =
      case result do
        {:ok, %{result: text}} -> text
        {:ok, text} when is_binary(text) -> text
        {:ok, map} when is_map(map) -> inspect(map)
        {:error, _reason, %{message: msg}} -> "Error: #{msg}"
        {:error, _reason, details} -> "Error: #{inspect(details)}"
        {:error, %{message: msg}} -> "Error: #{msg}"
        {:error, text} when is_binary(text) -> "Error: #{text}"
        {:error, reason} -> "Error: #{inspect(reason)}"
      end

    sanitize_utf8(text)
  end

  # Replace invalid UTF-8 bytes with the Unicode replacement character (U+FFFD)
  # so that downstream JSON encoding (Jason) never crashes.
  defp sanitize_utf8(text) when is_binary(text) do
    if String.valid?(text) do
      text
    else
      # :unicode.characters_to_binary with :latin1 input replaces invalid sequences
      text
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        result when is_binary(result) -> result
        _ -> strip_invalid_utf8(text, <<>>)
      end
    end
  end

  defp sanitize_utf8(nil), do: ""

  defp strip_invalid_utf8(<<>>, acc), do: acc

  defp strip_invalid_utf8(<<c::utf8, rest::binary>>, acc),
    do: strip_invalid_utf8(rest, <<acc::binary, c::utf8>>)

  defp strip_invalid_utf8(<<_byte, rest::binary>>, acc),
    do: strip_invalid_utf8(rest, <<acc::binary, "�"::utf8>>)

  defp parse_model(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      _ -> {"zai", model_string}
    end
  end

  defp build_tool_definitions([]), do: []

  defp build_tool_definitions(tools) do
    Jido.AI.ToolAdapter.from_actions(tools)
  end

  defp call_llm(provider, model_id, messages, opts) do
    {config, opts} = Keyword.pop(opts, :stream_config)
    model_spec = "#{provider}:#{model_id}"

    if config, do: emit(config, :stream_start, %{})

    result =
      try do
        with {:ok, stream_response} <- Loomkin.LLM.stream_text(model_spec, messages, opts) do
          ReqLLM.StreamResponse.process_stream(stream_response,
            on_result: fn text ->
              if config, do: emit(config, :stream_delta, %{text: text})
            end,
            on_tool_call: fn _chunk -> :ok end
          )
        end
      rescue
        e -> {:error, Exception.message(e)}
      end

    if config, do: emit(config, :stream_end, %{})

    result
  end

  defp build_req_messages(windowed_messages) do
    Enum.map(windowed_messages, fn msg ->
      case msg.role do
        :system ->
          ReqLLM.Context.system(msg.content)

        :user ->
          ReqLLM.Context.user(msg.content)

        :assistant ->
          if msg[:tool_calls] && msg[:tool_calls] != [] do
            tool_calls =
              Enum.map(msg.tool_calls, fn tc ->
                {tc[:name] || tc["name"], tc[:arguments] || tc["arguments"] || %{},
                 id: tc[:id] || tc["id"]}
              end)

            ReqLLM.Context.assistant(msg.content || "", tool_calls: tool_calls)
          else
            ReqLLM.Context.assistant(msg.content || "")
          end

        :tool ->
          ReqLLM.Context.tool_result(
            msg[:tool_call_id] || "",
            msg.content || ""
          )
      end
    end)
  end

  defp emit(config, event_name, payload) do
    config.on_event.(event_name, payload)
  end

  defp emit_usage(config, response) do
    usage = extract_usage(response)
    emit(config, :usage, usage)
  end

  defp extract_usage(response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage ->
        %{
          input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
          output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0,
          total_cost: usage[:total_cost] || usage["total_cost"] || 0
        }

      _ ->
        %{input_tokens: 0, output_tokens: 0, total_cost: 0}
    end
  end

  defp maybe_auto_offload(messages, %{
         team_id: team_id,
         agent_name: agent_name,
         model: model,
         on_event: on_event
       })
       when not is_nil(team_id) and not is_nil(agent_name) do
    state = %{team_id: team_id, name: agent_name, messages: messages, model: model}

    case ContextOffload.maybe_offload(state) do
      {:offloaded, updated_messages, entry} ->
        on_event.(:context_offloaded, %{entry: entry})
        updated_messages

      :noop ->
        messages
    end
  end

  defp maybe_auto_offload(messages, _config), do: messages

  defp maybe_acquire_rate_limit(%{rate_limiter: nil}, _provider), do: :ok
  defp maybe_acquire_rate_limit(%{rate_limiter: callback}, provider), do: callback.(provider)

  # -- Failure memory keepers --------------------------------------------------

  defp maybe_record_failure_memory(config, tool_name, error_text, classification) do
    team_id = config.team_id
    agent_name = config.agent_name

    if team_id && agent_name do
      failure_data = %{
        "error_category" => to_string(classification.category),
        "tool_name" => tool_name,
        "error_message" => String.slice(error_text, 0, 2000),
        "severity" => to_string(classification.severity),
        "healable" => classification.healable,
        "suggested_approach" => classification.suggested_approach,
        "agent_name" => to_string(agent_name),
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
      }

      messages = [
        %{
          role: :system,
          content:
            "Failure record: tool=#{tool_name} category=#{classification.category} " <>
              "severity=#{classification.severity}\n#{error_text}"
        }
      ]

      ContextOffload.offload_to_keeper(
        team_id,
        agent_name,
        messages,
        topic: "failures:#{agent_name}",
        metadata: Map.put(failure_data, "type", "failure_memory")
      )
    end
  rescue
    _ -> :ok
  end

  @doc """
  Bootstrap failure memory for an agent by searching for past failure keepers
  and injecting lessons learned into the message list.

  Returns the messages list with a lessons-learned system message prepended
  if relevant failures were found, or the original messages unchanged.
  """
  def bootstrap_failure_memory(messages, config) do
    team_id = config.team_id
    agent_name = config.agent_name

    if team_id && agent_name do
      alias Loomkin.Teams.ContextRetrieval

      case ContextRetrieval.synthesize(
             team_id,
             "What errors occurred for #{agent_name}? What patterns? What was fixed?",
             agent_name: to_string(agent_name)
           ) do
        {:ok, summary} when is_binary(summary) and summary != "" ->
          lesson = %{
            role: :system,
            content: "[Lessons from past failures]\n#{String.slice(summary, 0, 3000)}",
            priority: :high
          }

          [lesson | messages]

        _ ->
          messages
      end
    else
      messages
    end
  rescue
    _ -> messages
  end
end
