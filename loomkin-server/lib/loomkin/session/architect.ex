defmodule Loomkin.Session.Architect do
  @moduledoc """
  Architect/Editor two-model workflow.

  Inspired by Aider's architect mode: a powerful model (architect) plans changes,
  then a fast model (editor) executes them.

  ## Flow

  1. **Architect phase**: Strong model receives full context and produces a structured edit plan.
     Sees: decision graph context, repo map, conversation history, all tool definitions.
     Outputs: JSON-structured plan with `[{file, action, description, details}]`.

  2. **Editor phase**: Fast model receives specific files + edit instructions from the plan.
     Executes file_read, file_edit, file_write tools to make changes.
     Reports back results per plan item.
  """

  require Logger

  alias Loomkin.Session.ContextWindow
  alias Loomkin.Session.Persistence
  alias Loomkin.Telemetry, as: LoomkinTelemetry

  # Planning-phase tools: the architect can spawn teams for complex tasks
  @planning_tools [
    Loomkin.Tools.TeamSpawn,
    Loomkin.Tools.TeamAssign,
    Loomkin.Tools.TeamProgress
  ]

  @doc """
  Run the full architect -> editor pipeline.

  1. Sends user request to architect model to get a structured plan
  2. Executes each plan item via the editor model
  3. Returns combined results

  Returns `{:ok, response_text, updated_state}` or `{:error, reason, state}`.
  """
  def run(user_text, state, opts \\ []) do
    architect_model = resolve_architect_model(opts)
    editor_model = resolve_editor_model(opts)

    # Fast-path: skip planning for trivial messages (greetings, thanks, etc.)
    if trivial_message?(user_text) do
      # Add user message to in-memory state and broadcast for UI,
      # but defer DB save until response is ready (atomic exchange).
      user_msg = %{role: :user, content: user_text}
      state = %{state | messages: state.messages ++ [user_msg]}
      broadcast(state.id, {:new_message, state.id, user_msg})

      conversational_fallback(user_text, state, architect_model, defer_user_save: true)
    else
      run_planning(user_text, state, architect_model, editor_model, opts)
    end
  end

  defp run_planning(user_text, state, architect_model, editor_model, _opts) do
    broadcast(state.id, {:architect_phase, :planning})

    case plan(user_text, state, architect_model: architect_model) do
      {:ok, plan_data, state} ->
        steps = plan_data["plan"] || []
        team_spawned = plan_data["team_spawned"] == true

        cond do
          team_spawned ->
            # Team was spawned to handle the task — don't fall back or re-plan
            summary = plan_data["summary"] || "Team spawned to handle task"
            {:ok, summary, state}

          steps == [] ->
            conversational_fallback(user_text, state, architect_model)

          true ->
            broadcast(state.id, {:architect_phase, :executing})
            execute_plan(plan_data, state, editor_model: editor_model)
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  @doc """
  Plan phase: sends user request to architect model and returns a structured plan.

  The architect model sees full context (system prompt, repo map, decision graph,
  conversation history) and produces a JSON plan.
  """
  def plan(user_text, state, opts \\ []) do
    architect_model = Keyword.get(opts, :architect_model, resolve_architect_model(opts))

    system_prompt = build_architect_prompt(state)

    windowed =
      ContextWindow.build_messages(state.messages, system_prompt,
        model: architect_model,
        session_id: state.id,
        project_path: state.project_path
      )

    {provider, model_id} = parse_model(architect_model)
    req_messages = build_req_messages(windowed)

    # Add the user's request with explicit architect instruction
    architect_user_msg = %{
      role: :user,
      content: """
      #{user_text}

      Respond with a JSON object containing your edit plan. The plan should have:
      - "summary": brief description of what will be done
      - "plan": array of steps, each with "file", "action" (create/edit/delete), "description", and "details"

      The "details" field should contain specific, precise instructions the editor can follow
      without needing additional context. Include exact code to write or specific changes to make.
      """
    }

    req_messages = req_messages ++ [ReqLLM.Context.user(architect_user_msg.content)]

    # Save user message to conversation
    {:ok, _} =
      Persistence.save_message(%{
        session_id: state.id,
        role: :user,
        content: user_text
      })

    user_msg = %{role: :user, content: user_text}
    state = %{state | messages: state.messages ++ [user_msg]}
    broadcast(state.id, {:new_message, state.id, user_msg})

    # Include planning tools so the architect can spawn teams for complex tasks.
    # The architect can choose between a file-based plan OR using team_spawn.
    planning_tool_defs = Jido.AI.ToolAdapter.from_actions(@planning_tools)
    opts = if planning_tool_defs != [], do: [tools: planning_tool_defs], else: []

    telemetry_meta = %{
      session_id: state.id,
      model: architect_model,
      architect_phase: :plan
    }

    on_retry = fn attempt, reason, backoff_ms ->
      broadcast(
        state.id,
        {:llm_retry, state.id,
         %{attempt: attempt, reason: inspect(reason), backoff_ms: backoff_ms}}
      )
    end

    case Loomkin.LLMRetry.with_retry([on_retry: on_retry], fn ->
           LoomkinTelemetry.span_llm_request(telemetry_meta, fn ->
             call_llm(provider, model_id, req_messages, [{:session_id, state.id} | opts])
           end)
         end) do
      {:ok, response} ->
        # Check if the architect chose to use tools (e.g. team_spawn) instead of a JSON plan
        classified = ReqLLM.Response.classify(response)

        if classified.type == :tool_calls do
          update_usage(state.id, response)

          handle_planning_tool_calls(
            classified,
            response,
            provider,
            model_id,
            req_messages,
            state,
            opts,
            user_text
          )
        else
          text = extract_text(response)
          update_usage(state.id, response)

          case parse_plan_with_retry(text, provider, model_id, req_messages, state, opts) do
            {:ok, plan_data, state} ->
              steps = plan_data["plan"] || []

              state =
                if steps != [] do
                  plan_summary = format_plan_summary(plan_data)

                  {:ok, _} =
                    Persistence.save_message(%{
                      session_id: state.id,
                      role: :assistant,
                      content: plan_summary
                    })

                  assistant_msg = %{role: :assistant, content: plan_summary, from: "Architect"}
                  state = %{state | messages: state.messages ++ [assistant_msg]}
                  broadcast(state.id, {:new_message, state.id, assistant_msg})
                  broadcast(state.id, {:architect_plan, state.id, plan_data})
                  state
                else
                  state
                end

              {:ok, plan_data, state}

            {:error, reason, state} ->
              {:error, "Failed to parse architect plan: #{reason}", state}
          end
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc """
  Execute phase: sends plan items to the editor model one at a time.

  Each plan item is sent with the target file content and specific edit instructions.
  The editor model uses tools (file_read, file_edit, file_write) to make changes.
  """
  def execute(plan_data, state, opts \\ []) do
    execute_plan(plan_data, state, opts)
  end

  # --- Private ---

  # Handle tool calls from the planning phase (e.g. team_spawn, team_assign).
  # Executes tools, bootstraps lead agent with user request, notifies session.
  defp handle_planning_tool_calls(
         classified,
         _response,
         _provider,
         _model_id,
         _req_messages,
         state,
         _opts,
         user_text
       ) do
    tool_calls = classified.tool_calls

    {results, spawned_team_ids} =
      Enum.reduce(tool_calls, {[], []}, fn tool_call, {res, team_ids} ->
        tool_name = tool_call[:name] || tool_call["name"]
        tool_args = tool_call[:arguments] || tool_call["arguments"] || %{}

        context = %{
          project_path: state.project_path,
          session_id: state.id,
          parent_team_id: state.team_id,
          model: state.model
        }

        case Jido.AI.ToolAdapter.lookup_action(tool_name, @planning_tools) do
          {:ok, tool_module} ->
            normalized_args = atomize_keys(tool_args)

            case Jido.Exec.run(tool_module, normalized_args, context, timeout: 60_000) do
              {:ok, %{team_id: tid, result: text}} ->
                {res ++ [text], team_ids ++ [tid]}

              {:ok, %{result: text}} ->
                {res ++ [text], team_ids}

              {:ok, text} when is_binary(text) ->
                {res ++ [text], team_ids}

              {:error, reason} ->
                {res ++ ["Error: #{inspect(reason)}"], team_ids}
            end

          {:error, :not_found} ->
            {res ++ ["Error: Planning tool '#{tool_name}' not found"], team_ids}
        end
      end)

    response_text = Enum.join(results, "\n\n")

    # Bootstrap: send the user's request to each spawned team's lead agent
    for team_id <- spawned_team_ids do
      bootstrap_team_lead(team_id, user_text)

      # Notify the session about this child team
      if state.id do
        case Loomkin.Session.Manager.find_session(state.id) do
          {:ok, session_pid} -> send(session_pid, {:child_team_created, team_id})
          :error -> :ok
        end
      end
    end

    status_text =
      if spawned_team_ids != [] do
        "Team working on your request...\n\n#{response_text}"
      else
        response_text
      end

    {:ok, _} =
      Persistence.save_message(%{
        session_id: state.id,
        role: :assistant,
        content: status_text
      })

    assistant_msg = %{role: :assistant, content: status_text, from: "Architect"}
    state = %{state | messages: state.messages ++ [assistant_msg]}
    broadcast(state.id, {:new_message, state.id, assistant_msg})

    # Signal that the team was spawned — run/3 should not fall back to conversational
    {:ok, %{"plan" => [], "summary" => status_text, "team_spawned" => true}, state}
  end

  # Find and message the lead agent (or first agent) in a newly spawned team.
  defp bootstrap_team_lead(team_id, user_text) do
    alias Loomkin.Teams.Agent
    alias Loomkin.Teams.Manager

    agents = Manager.list_agents(team_id)

    lead =
      Enum.find(agents, fn a -> a.role == :lead end) ||
        List.first(agents)

    if lead do
      Task.Supervisor.start_child(Loomkin.Teams.TaskSupervisor, fn ->
        Agent.send_message(lead.pid, user_text)
      end)
    end
  end

  defp conversational_fallback(user_text, state, model, opts \\ []) do
    {provider, model_id} = parse_model(model)
    defer_user_save = Keyword.get(opts, :defer_user_save, false)

    system_prompt = """
    You are Loomkin, an AI coding assistant. Respond helpfully to the user's request.
    You have access to the project at: #{state.project_path}

    Be concise and direct. If the user is asking to explore or understand the codebase,
    describe what you can see and suggest next steps.
    """

    # Use ContextWindow to build enriched, windowed messages with full history
    windowed =
      ContextWindow.build_messages(state.messages, system_prompt,
        model: model,
        session_id: state.id,
        project_path: state.project_path
      )

    messages = build_req_messages(windowed)

    telemetry_meta = %{session_id: state.id, model: model, architect_phase: :conversational}

    on_retry = fn attempt, reason, backoff_ms ->
      broadcast(
        state.id,
        {:llm_retry, state.id,
         %{attempt: attempt, reason: inspect(reason), backoff_ms: backoff_ms}}
      )
    end

    case Loomkin.LLMRetry.with_retry([on_retry: on_retry], fn ->
           LoomkinTelemetry.span_llm_request(telemetry_meta, fn ->
             call_llm(provider, model_id, messages, session_id: state.id)
           end)
         end) do
      {:ok, response} ->
        text = extract_text(response)

        # When user save was deferred, save both atomically to prevent orphans
        if defer_user_save do
          {:ok, _} = Persistence.save_exchange(state.id, user_text, text)
        else
          {:ok, _} =
            Persistence.save_message(%{session_id: state.id, role: :assistant, content: text})
        end

        assistant_msg = %{role: :assistant, content: text, from: "Architect"}
        state = %{state | messages: state.messages ++ [assistant_msg]}
        broadcast(state.id, {:new_message, state.id, assistant_msg})
        update_usage(state.id, response)
        {:ok, text, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp execute_plan(plan_data, state, opts) do
    editor_model = Keyword.get(opts, :editor_model, resolve_editor_model(opts))
    steps = plan_data["plan"] || []

    {results, state} =
      Enum.reduce(steps, {[], state}, fn step, {results, state} ->
        broadcast(state.id, {:architect_step, state.id, step})

        case execute_step(step, state, editor_model) do
          {:ok, result, state} ->
            {results ++ [%{step: step, status: :ok, result: result}], state}

          {:error, reason, state} ->
            {results ++ [%{step: step, status: :error, result: reason}], state}
        end
      end)

    # Build summary response
    response = format_execution_results(plan_data, results)

    {:ok, _} =
      Persistence.save_message(%{
        session_id: state.id,
        role: :assistant,
        content: response
      })

    assistant_msg = %{role: :assistant, content: response, from: "Architect"}
    state = %{state | messages: state.messages ++ [assistant_msg]}
    broadcast(state.id, {:new_message, state.id, assistant_msg})

    {:ok, response, state}
  end

  defp execute_step(step, state, editor_model) do
    file = step["file"]
    action = step["action"]
    details = step["details"]
    description = step["description"]

    # Build a focused prompt for the editor
    editor_prompt = build_editor_prompt(file, action, description, details, state)

    {provider, model_id} = parse_model(editor_model)
    req_messages = [ReqLLM.Context.system(editor_prompt)]

    editor_instruction =
      "Execute the following edit:\nFile: #{file}\nAction: #{action}\nInstructions: #{details}"

    req_messages = req_messages ++ [ReqLLM.Context.user(editor_instruction)]

    # Provide tool definitions for the editor
    tool_defs = build_editor_tool_definitions(state.tools)
    opts = if tool_defs != [], do: [tools: tool_defs], else: []

    case editor_loop(provider, model_id, req_messages, state, opts, 0) do
      {:ok, result_text, state} ->
        {:ok, result_text, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  @max_editor_iterations 10

  defp editor_loop(_provider, _model_id, _messages, state, _opts, iteration)
       when iteration >= @max_editor_iterations do
    {:error, "Editor exceeded maximum iterations", state}
  end

  defp editor_loop(provider, model_id, messages, state, opts, iteration) do
    telemetry_meta = %{
      session_id: state.id,
      model: "#{provider}:#{model_id}",
      architect_phase: :edit,
      iteration: iteration
    }

    on_retry = fn attempt, reason, backoff_ms ->
      broadcast(
        state.id,
        {:llm_retry, state.id,
         %{attempt: attempt, reason: inspect(reason), backoff_ms: backoff_ms}}
      )
    end

    case Loomkin.LLMRetry.with_retry([on_retry: on_retry], fn ->
           LoomkinTelemetry.span_llm_request(telemetry_meta, fn ->
             call_llm(provider, model_id, messages, [{:session_id, state.id} | opts])
           end)
         end) do
      {:ok, response} ->
        classified = ReqLLM.Response.classify(response)

        handle_editor_response(
          classified,
          response,
          provider,
          model_id,
          messages,
          state,
          opts,
          iteration
        )

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_editor_response(
         %{type: :tool_calls} = classified,
         response,
         provider,
         model_id,
         messages,
         state,
         opts,
         iteration
       ) do
    # Execute tools in the editor context
    assistant_content = classified.text || ""
    tool_calls = classified.tool_calls

    tool_call_msgs =
      Enum.map(tool_calls, fn tc ->
        {tc[:name] || tc["name"], tc[:arguments] || tc["arguments"] || %{},
         id: tc[:id] || tc["id"]}
      end)

    messages =
      messages ++ [ReqLLM.Context.assistant(assistant_content, tool_calls: tool_call_msgs)]

    # Execute each tool call (with permission checks)
    {messages, state} =
      Enum.reduce(tool_calls, {messages, state}, fn tool_call, {msgs, st} ->
        tool_name = tool_call[:name]
        tool_args = tool_call[:arguments] || %{}
        tool_call_id = tool_call[:id] || "call_#{Ecto.UUID.generate()}"
        context = %{project_path: st.project_path, session_id: st.id}

        # Extract path for permission check
        tool_path = tool_args["file_path"] || tool_args["path"] || "*"

        result_text =
          case check_editor_permission(to_string(tool_name), tool_path, st.id) do
            :allowed ->
              case Jido.AI.ToolAdapter.lookup_action(tool_name, st.tools) do
                {:ok, tool_module} ->
                  tool_meta = %{
                    tool_name: tool_name,
                    session_id: st.id
                  }

                  LoomkinTelemetry.span_tool_execute(tool_meta, fn ->
                    run_and_format_tool(tool_module, tool_args, context)
                  end)

                {:error, :not_found} ->
                  "Error: Tool '#{tool_name}' not found"
              end

            :denied ->
              "Error: Permission denied for #{tool_name} on #{tool_path}"
          end

        broadcast(st.id, {:tool_executing, st.id, tool_name})
        broadcast(st.id, {:tool_complete, st.id, tool_name, result_text})

        msgs = msgs ++ [ReqLLM.Context.tool_result(tool_call_id, result_text)]
        {msgs, st}
      end)

    update_usage(state.id, response)
    editor_loop(provider, model_id, messages, state, opts, iteration + 1)
  end

  defp handle_editor_response(
         %{type: :final_answer} = classified,
         response,
         _provider,
         _model_id,
         _messages,
         state,
         _opts,
         _iteration
       ) do
    update_usage(state.id, response)
    {:ok, classified.text, state}
  end

  defp build_architect_prompt(state) do
    """
    You are the Architect — a senior software engineer planning code changes.

    Project path: #{state.project_path}

    Your job is to analyze the user's request and decide the best execution strategy.

    ## Strategy Options

    ### 1. Team spawn (DEFAULT — use for most tasks)
    Use the `team_spawn` tool to create a team of specialized agents. **This is the default strategy.**
    Spawn a team when ANY of these apply:
    - The task touches 2+ files
    - The task requires reading code before changing it (research + implementation)
    - The scope is unclear and needs exploration first
    - The task involves exploration, analysis, or investigation
    - The task benefits from parallel work (e.g. research while coding)
    - The task is non-trivial in any way

    **Team composition guidance:**
    - Minimum: researcher + coder (always include both)
    - Add a reviewer for changes to critical paths, public APIs, or security-sensitive code
    - Add a tester when the task involves testable behavior changes
    - Add a lead when the team has 3+ agents to coordinate work

    After spawning a team, use `team_assign` to delegate specific subtasks to each agent.
    Be specific in task descriptions — include file paths, function names, and acceptance criteria.

    **When in doubt, spawn a team.** Teams are cheap; missed collaboration is expensive.

    ### 2. File-based edit plan (ONLY for trivial single-file edits)
    Respond with a JSON object containing your edit plan:
    - "summary": brief description of what will be done
    - "plan": array of steps, each with "file", "action" (create/edit/delete), "description", and "details"

    Use this ONLY when:
    - The change is a single file with obvious, mechanical edits (typo fix, config value change)
    - No exploration or research is needed
    - The change is completely unambiguous

    ## Guidelines
    - Default to spawning a team — solo JSON plans are the exception, not the rule
    - Be thorough and specific in task assignments and edit plan details
    """
  end

  defp build_editor_prompt(file, action, description, _details, state) do
    base = """
    You are the Editor — a precise code executor. You make exactly the changes described.

    Project path: #{state.project_path}
    Target file: #{file}
    Action: #{action}
    Goal: #{description}

    Rules:
    - Make ONLY the changes described — no extras, no cleanup, no refactoring
    - Use the provided tools (file_read, file_edit, file_write) to make changes
    - Read the file first before editing it
    - After making changes, confirm what you did
    """

    case action do
      "create" ->
        base <> "\nCreate the file with the exact content specified in the instructions."

      "edit" ->
        base <> "\nRead the file first, then apply the specific edits described."

      "delete" ->
        base <> "\nDelete the specified file."

      _ ->
        base
    end
  end

  defp build_editor_tool_definitions(tools) do
    # Filter to only file-related tools for the editor
    editor_tool_names = ~w(file_read file_edit file_write directory_list)

    editor_tools =
      Enum.filter(tools, fn tool ->
        tool_name =
          cond do
            is_atom(tool) -> tool.name()
            is_map(tool) -> Map.get(tool, :name, "")
            true -> ""
          end

        to_string(tool_name) in editor_tool_names
      end)

    if editor_tools != [] do
      Jido.AI.ToolAdapter.from_actions(editor_tools)
    else
      # Fall back to all tools if we can't filter
      Jido.AI.ToolAdapter.from_actions(tools)
    end
  end

  @max_json_retries 2

  defp parse_plan_with_retry(text, provider, model_id, req_messages, state, opts) do
    case parse_plan(text) do
      {:ok, plan_data} ->
        {:ok, plan_data, state}

      {:error, reason} ->
        retry_json_parse(text, reason, provider, model_id, req_messages, state, opts, 0)
    end
  end

  defp retry_json_parse(_text, reason, _provider, _model_id, _req_messages, state, _opts, attempt)
       when attempt >= @max_json_retries do
    {:error, reason, state}
  end

  defp retry_json_parse(text, reason, provider, model_id, req_messages, state, opts, attempt) do
    broadcast(
      state.id,
      {:llm_retry, state.id,
       %{attempt: attempt + 1, reason: "JSON parse error: #{reason}", backoff_ms: 0}}
    )

    fix_msg =
      ReqLLM.Context.user("""
      Your previous response was not valid JSON. Parse error: #{reason}

      Please respond with ONLY a valid JSON object containing:
      - "summary": brief description string
      - "plan": array of steps, each with "file", "action", "description", "details"

      Your previous response started with: #{String.slice(text, 0, 200)}
      """)

    corrected_messages = req_messages ++ [ReqLLM.Context.assistant(text), fix_msg]

    case call_llm(provider, model_id, corrected_messages, [{:session_id, state.id} | opts]) do
      {:ok, response} ->
        update_usage(state.id, response)
        corrected_text = extract_text(response)

        case parse_plan(corrected_text) do
          {:ok, plan_data} ->
            {:ok, plan_data, state}

          {:error, new_reason} ->
            retry_json_parse(
              corrected_text,
              new_reason,
              provider,
              model_id,
              req_messages,
              state,
              opts,
              attempt + 1
            )
        end

      {:error, llm_reason} ->
        {:error, "LLM retry failed: #{inspect(llm_reason)}", state}
    end
  end

  defp parse_plan(text) when is_binary(text) do
    # Try to extract JSON from the response
    json_text = extract_json(text)

    case Jason.decode(json_text) do
      {:ok, %{"plan" => plan, "summary" => summary} = data}
      when is_list(plan) and is_binary(summary) ->
        {:ok, data}

      {:ok, %{"plan" => plan} = data} when is_list(plan) ->
        {:ok, Map.put_new(data, "summary", "Edit plan with #{length(plan)} steps")}

      {:ok, _other} ->
        {:error, "Response is valid JSON but missing required 'plan' array"}

      {:error, reason} ->
        {:error, "Invalid JSON: #{inspect(reason)}"}
    end
  end

  defp parse_plan(_), do: {:error, "Empty response from architect"}

  defp extract_json(text) do
    # Try to find JSON block in markdown code fences
    case Regex.run(~r/```(?:json)?\s*\n([\s\S]*?)\n\s*```/, text) do
      [_, json] -> String.trim(json)
      nil -> String.trim(text)
    end
  end

  defp format_plan_summary(plan_data) do
    summary = plan_data["summary"] || "Edit plan"
    steps = plan_data["plan"] || []

    step_list =
      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {step, i} ->
        "#{i}. **#{step["action"]}** `#{step["file"]}` — #{step["description"]}"
      end)
      |> Enum.join("\n")

    """
    ## Architect Plan

    #{summary}

    ### Steps:
    #{step_list}

    _Executing plan with editor model..._
    """
  end

  defp format_execution_results(plan_data, results) do
    summary = plan_data["summary"] || "Edit plan"

    step_results =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {%{step: step, status: status, result: result}, i} ->
        status_icon = if status == :ok, do: "[OK]", else: "[FAILED]"
        result_preview = safe_truncate(to_string(result), 200)
        "#{i}. #{status_icon} #{step["action"]} `#{step["file"]}` — #{result_preview}"
      end)
      |> Enum.join("\n")

    succeeded = Enum.count(results, &(&1.status == :ok))
    total = length(results)

    """
    ## Execution Complete

    #{summary}

    ### Results (#{succeeded}/#{total} succeeded):
    #{step_results}
    """
  end

  # Truncate text safely — close any open code fences to avoid breaking markdown
  defp safe_truncate(text, max_len) do
    if String.length(text) <= max_len do
      text
    else
      truncated = String.slice(text, 0, max_len)
      # Count backtick fences — if odd, we have an unclosed fence
      fence_count = length(Regex.scan(~r/```/, truncated))

      if rem(fence_count, 2) == 1 do
        truncated <> "\n```\n... (truncated)"
      else
        truncated <> "... (truncated)"
      end
    end
  end

  defp check_editor_permission(tool_name, tool_path, session_id) do
    case Loomkin.Permissions.Manager.check(tool_name, tool_path, session_id) do
      :allowed ->
        :allowed

      :ask ->
        # Notify Session GenServer so it can forward the user's decision back
        case Loomkin.Session.Manager.find_session(session_id) do
          {:ok, session_pid} ->
            send(session_pid, {:permission_pending, self(), tool_name, tool_path})

          :error ->
            :ok
        end

        broadcast(session_id, {:permission_request, session_id, tool_name, tool_path, :session})

        receive do
          {:permission_decision, action, ^tool_name, _tool_result} ->
            if action in ["allow_once", "allow_always"], do: :allowed, else: :denied
        after
          60_000 -> :denied
        end
    end
  end

  defp run_and_format_tool(tool_module, tool_args, context) do
    # LLM sends string keys — Jido.Exec expects atom keys for NimbleOptions validation
    normalized_args = atomize_keys(tool_args)

    result =
      try do
        Jido.Exec.run(tool_module, normalized_args, context, timeout: 60_000)
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      {:ok, %{result: text}} -> text
      {:ok, text} when is_binary(text) -> text
      {:ok, map} when is_map(map) -> inspect(map)
      {:error, %{message: msg}} -> "Error: #{msg}"
      {:error, text} when is_binary(text) -> "Error: #{text}"
      {:error, reason} -> "Error: #{inspect(reason)}"
    end
  end

  defp extract_text(response) do
    classified = ReqLLM.Response.classify(response)
    classified.text
  end

  defp call_llm(provider, model_id, messages, opts) do
    {session_id, opts} = Keyword.pop(opts, :session_id)
    model_spec = "#{provider}:#{model_id}"

    if session_id do
      broadcast(session_id, {:stream_start, session_id})
    end

    result =
      try do
        with {:ok, stream_response} <- Loomkin.LLM.stream_text(model_spec, messages, opts) do
          ReqLLM.StreamResponse.process_stream(stream_response,
            on_result: fn text ->
              if session_id do
                broadcast(session_id, {:stream_delta, session_id, %{text: text}})
              end
            end,
            on_tool_call: fn _chunk -> :ok end
          )
        end
      rescue
        e ->
          {:error, Exception.message(e)}
      end

    if session_id do
      broadcast(session_id, {:stream_end, session_id})
    end

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
          ReqLLM.Context.tool_result(msg[:tool_call_id] || "", msg.content || "")
      end
    end)
  end

  # Delegate to Registry.atomize_keys which uses a known-key allowlist
  # instead of String.to_atom, preventing atom table exhaustion from LLM output.
  defp atomize_keys(data), do: Loomkin.Tools.Registry.atomize_keys(data)

  # Detect trivial messages (greetings, thanks, etc.) that should bypass architect planning.
  # Only matches when the entire message is a short greeting — any substantial content passes through.
  @trivial_patterns ~w(hi hello hey yo sup thanks thank cheers cool ok okay yes no bye goodbye)

  defp trivial_message?(text) do
    normalized =
      text
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[!?.,:;]+$/, "")
      |> String.trim()

    # Only trivial if the entire message is a short greeting (≤ 3 words)
    word_count = normalized |> String.split(~r/\s+/, trim: true) |> length()

    word_count <= 3 and
      Enum.any?(@trivial_patterns, fn pat -> String.contains?(normalized, pat) end)
  end

  defp parse_model(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      _ -> {"zai", model_string}
    end
  end

  defp resolve_architect_model(opts) do
    # Use the user-selected model (passed via opts from the session).
    # Falls back to config, then a sensible default.
    Keyword.get(opts, :architect_model) ||
      Loomkin.Config.get(:model, :default)
  end

  defp resolve_editor_model(opts) do
    # Only use a secondary model when the user has explicitly configured one.
    # If no secondary model is set, fall back to the architect (primary) model
    # so everything runs on the single model the user selected.
    Keyword.get(opts, :editor_model) ||
      Loomkin.Config.get(:model, :editor) ||
      resolve_architect_model(opts)
  end

  defp update_usage(session_id, response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage ->
        input = usage[:input_tokens] || usage["input_tokens"] || 0
        output = usage[:output_tokens] || usage["output_tokens"] || 0
        cost = usage[:total_cost] || usage["total_cost"] || 0
        Persistence.update_costs(session_id, input, output, cost)

      _ ->
        :ok
    end
  end

  defp broadcast(session_id, {:new_message, _sid, msg}) do
    signal = Loomkin.Signals.Session.NewMessage.new!(%{session_id: session_id})
    Loomkin.Signals.publish(%{signal | data: Map.put(signal.data, :message, msg)})
  rescue
    e ->
      Logger.warning("[Architect] broadcast :new_message failed: #{inspect(e)}")
  end

  defp broadcast(session_id, {:permission_request, _sid, tool_name, tool_path, :session}) do
    signal =
      Loomkin.Signals.Session.PermissionRequest.new!(%{
        session_id: session_id,
        tool_name: tool_name,
        tool_path: tool_path
      })

    Loomkin.Signals.publish(signal)
  rescue
    e ->
      Logger.warning("[Architect] broadcast :permission_request failed: #{inspect(e)}")
  end

  defp broadcast(session_id, {:stream_start, _sid}) do
    signal =
      Loomkin.Signals.Session.StatusChanged.new!(%{session_id: session_id, status: :streaming})

    Loomkin.Signals.publish(%{
      signal
      | data: Map.put(signal.data, :raw_event, {:stream_start, session_id})
    })
  rescue
    e ->
      Logger.warning("[Architect] broadcast :stream_start failed: #{inspect(e)}")
  end

  defp broadcast(session_id, {:stream_delta, _sid, payload}) do
    signal =
      Loomkin.Signals.Session.StatusChanged.new!(%{session_id: session_id, status: :streaming})

    Loomkin.Signals.publish(%{
      signal
      | data: Map.put(signal.data, :raw_event, {:stream_delta, session_id, payload})
    })
  rescue
    e ->
      Logger.warning("[Architect] broadcast :stream_delta failed: #{inspect(e)}")
  end

  defp broadcast(session_id, {:stream_end, _sid}) do
    signal =
      Loomkin.Signals.Session.StatusChanged.new!(%{session_id: session_id, status: :idle})

    Loomkin.Signals.publish(%{
      signal
      | data: Map.put(signal.data, :raw_event, {:stream_end, session_id})
    })
  rescue
    e ->
      Logger.warning("[Architect] broadcast :stream_end failed: #{inspect(e)}")
  end

  defp broadcast(session_id, event) do
    Logger.warning(
      "[Architect] unhandled broadcast event for #{session_id}: #{inspect(event, limit: 200)}"
    )
  end
end
