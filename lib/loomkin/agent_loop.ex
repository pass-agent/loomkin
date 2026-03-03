defmodule Loomkin.AgentLoop do
  @moduledoc """
  Reusable ReAct agent loop. Used by both Loomkin.Session and Loomkin.Teams.Agent.

  The loop is parameterized via callbacks so callers can control persistence,
  event broadcasting, and permission handling without coupling to any specific
  GenServer or PubSub topology.
  """

  alias Loomkin.Session.ContextWindow
  alias Loomkin.Teams.ContextOffload
  alias Loomkin.Telemetry, as: LoomkinTelemetry

  require Logger

  @max_rate_limit_retries 3
  @max_iterations 25

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

  Returns `{:ok, response_text, messages, metadata}` or `{:error, reason, messages}`.

  The `messages` list returned always includes the full updated conversation
  (input messages + new assistant/tool messages from the loop), so the caller
  can persist or discard them as needed.
  """
  @spec run([map()], keyword()) ::
          {:ok, String.t(), [map()], map()}
          | {:error, term(), [map()]}
          | {:pending_permission, map(), [map()]}
  def run(messages, opts) do
    config = build_config(opts)
    run_with_rate_limit_retry(messages, config, 0)
  end

  defp run_with_rate_limit_retry(messages, config, attempt) do
    try do
      do_loop(messages, config, 0)
    catch
      {:budget_exceeded, scope} ->
        error_msg = "Budget exceeded (#{scope}). Stopping agent loop."
        Logger.warning(error_msg)
        {:error, error_msg, messages}

      {:rate_limited, provider} ->
        if attempt < @max_rate_limit_retries do
          backoff_ms = Integer.pow(2, attempt) * 1_000

          Logger.warning(
            "Rate limited by #{provider}, retry #{attempt + 1}/#{@max_rate_limit_retries} after #{backoff_ms}ms"
          )

          config.on_event.(:rate_limited, %{
            provider: provider,
            retry: attempt + 1,
            backoff_ms: backoff_ms
          })

          Process.sleep(backoff_ms)
          run_with_rate_limit_retry(messages, config, attempt + 1)
        else
          Logger.warning(
            "Rate limited by #{provider}, max retries (#{@max_rate_limit_retries}) exhausted"
          )

          {:error, :rate_limited, messages}
        end
    end
  end

  # -- Config ------------------------------------------------------------------

  defp build_config(opts) do
    %{
      model: Keyword.fetch!(opts, :model),
      tools: Keyword.get(opts, :tools, []),
      system_prompt: Keyword.fetch!(opts, :system_prompt),
      project_path: Keyword.get(opts, :project_path),
      project_path_resolver: Keyword.get(opts, :project_path_resolver),
      session_id: Keyword.get(opts, :session_id),
      agent_name: Keyword.get(opts, :agent_name),
      team_id: Keyword.get(opts, :team_id),
      max_iterations: Keyword.get(opts, :max_iterations, @max_iterations),
      on_event: Keyword.get(opts, :on_event, fn _name, _payload -> :ok end),
      on_tool_execute: Keyword.get(opts, :on_tool_execute),
      check_permission: Keyword.get(opts, :check_permission),
      rate_limiter: Keyword.get(opts, :rate_limiter)
    }
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

    Logger.warning("AgentLoop: #{error_msg}")
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
        team_id: config[:team_id]
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

    Logger.debug(
      "AgentLoop calling LLM: #{provider}:#{model_id}, #{length(req_messages)} messages, #{length(opts[:tools] || [])} tools"
    )

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
        Logger.debug("AgentLoop LLM response type: #{classified.type}")
        handle_classified(classified, response, messages, config, iteration)

      {:error, reason} ->
        Logger.error("AgentLoop LLM error: #{inspect(reason)}")
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

    # Execute tool calls
    case execute_tool_calls(classified.tool_calls, messages, config) do
      {:ok, messages} ->
        emit_usage(config, response)
        do_loop(messages, config, iteration + 1)

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

  defp execute_tool_calls([], messages, _config), do: {:ok, messages}

  defp execute_tool_calls([tool_call | rest], messages, config) do
    case execute_single_tool(tool_call, messages, config) do
      {:ok, messages} ->
        execute_tool_calls(rest, messages, config)

      {:pending, pending_data, messages} ->
        {:pending, rest, messages, pending_data}
    end
  end

  defp execute_single_tool(tool_call, messages, config) do
    tool_name = tool_call[:name]
    tool_args = tool_call[:arguments] || %{}
    tool_call_id = tool_call[:id] || "call_#{Ecto.UUID.generate()}"
    tool_path = tool_args["file_path"] || tool_args["path"] || "*"

    # Dynamically resolve project_path at each tool execution
    effective_path = current_project_path(config)

    context = %{
      project_path: effective_path,
      session_id: config.session_id,
      agent_name: config.agent_name,
      team_id: config.team_id,
      parent_team_id: config.team_id,
      model: config.model
    }

    emit(config, :tool_executing, %{tool_name: tool_name, tool_target: tool_path})

    case Jido.AI.ToolAdapter.lookup_action(tool_name, config.tools) do
      {:error, :not_found} ->
        result_text = "Error: Tool '#{tool_name}' not found"
        messages = record_tool_result(messages, config, tool_name, tool_call_id, result_text)
        {:ok, messages}

      {:ok, tool_module} ->
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
                Map.put(context, :allowed_external_path,
                  Loomkin.Tool.resolve_path(tool_path, effective_path))
              else
                context
              end

            result_text = run_tool(tool_module, tool_args, context, config)
            messages = record_tool_result(messages, config, tool_name, tool_call_id, result_text)
            {:ok, messages}

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

  defp run_tool(tool_module, tool_args, context, config) do
    if config.on_tool_execute do
      config.on_tool_execute.(tool_module, tool_args, context)
    else
      default_run_tool(tool_module, tool_args, context)
    end
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

    result =
      LoomkinTelemetry.span_tool_execute(tool_meta, fn ->
        try do
          Jido.Exec.run(tool_module, atomized_args, context, timeout: 60_000)
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

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
    emit(config, :tool_complete, %{tool_name: tool_name, result: result_text})

    if String.starts_with?(result_text || "", "Error:") do
      emit(config, :tool_error, %{tool_name: tool_name, error: result_text})
    end

    tool_msg = %{role: :tool, content: result_text, tool_call_id: tool_call_id}
    emit(config, :new_message, tool_msg)

    messages ++ [tool_msg]
  end

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
  def resume(tool_result_text, pending_info, messages) do
    config = pending_info.config
    tool_call_id = pending_info.pending_data.tool_call_id
    tool_name = pending_info.pending_data.tool_name

    # Record the tool result
    messages = record_tool_result(messages, config, tool_name, tool_call_id, tool_result_text)

    # Process remaining tool calls from the batch
    case execute_tool_calls(pending_info.remaining_tool_calls, messages, config) do
      {:ok, messages} ->
        emit_usage(config, pending_info.response)
        do_loop(messages, config, pending_info.iteration + 1)

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

  # -- Helpers -----------------------------------------------------------------

  @doc false
  def format_tool_result(result) do
    text =
      case result do
        {:ok, %{result: text}} -> text
        {:ok, text} when is_binary(text) -> text
        {:ok, map} when is_map(map) -> inspect(map)
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

  defp sanitize_utf8(nil), do: nil

  defp strip_invalid_utf8(<<>>, acc), do: acc
  defp strip_invalid_utf8(<<c::utf8, rest::binary>>, acc), do: strip_invalid_utf8(rest, <<acc::binary, c::utf8>>)
  defp strip_invalid_utf8(<<_byte, rest::binary>>, acc), do: strip_invalid_utf8(rest, <<acc::binary, "�"::utf8>>)

  defp parse_model(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      _ -> {"anthropic", model_string}
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
        with {:ok, stream_response} <- ReqLLM.stream_text(model_spec, messages, opts) do
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
end
