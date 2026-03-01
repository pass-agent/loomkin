defmodule Loom.Session.Architect do
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

  alias Loom.Session.{ContextWindow, Persistence}
  alias Loom.Telemetry, as: LoomTelemetry

  require Logger

  # Planning-phase tools: the architect can spawn teams for complex tasks
  @planning_tools [
    Loom.Tools.TeamSpawn,
    Loom.Tools.TeamAssign,
    Loom.Tools.TeamProgress
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

    Logger.info("[Architect] Starting run — architect=#{architect_model} editor=#{editor_model} session=#{state.id}")
    broadcast(state.id, {:architect_phase, :planning})

    case plan(user_text, state, architect_model: architect_model) do
      {:ok, plan_data, state} ->
        steps = plan_data["plan"] || []
        team_spawned = plan_data["team_spawned"] == true

        cond do
          team_spawned ->
            # Team was spawned to handle the task — don't fall back or re-plan
            Logger.info("[Architect] Team spawned — delegating execution to agents")
            summary = plan_data["summary"] || "Team spawned to handle task"
            {:ok, summary, state}

          steps == [] ->
            Logger.info("[Architect] Plan returned 0 steps — falling back to conversational response")
            conversational_fallback(user_text, state, architect_model)

          true ->
            Logger.info("[Architect] Plan succeeded with #{length(steps)} steps, executing...")
            broadcast(state.id, {:architect_phase, :executing})
            execute_plan(plan_data, state, editor_model: editor_model)
        end

      {:error, reason, state} ->
        Logger.error("[Architect] Plan phase failed: #{inspect(reason)}")
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

    case LoomTelemetry.span_llm_request(telemetry_meta, fn ->
           call_llm(provider, model_id, req_messages, opts)
         end) do
      {:ok, response} ->
        # Check if the architect chose to use tools (e.g. team_spawn) instead of a JSON plan
        classified = ReqLLM.Response.classify(response)

        if classified.type == :tool_calls do
          Logger.info("[Architect] Planning phase invoked tools — executing team operations")
          update_usage(state.id, response)
          handle_planning_tool_calls(classified, response, provider, model_id, req_messages, state, opts)
        else
          text = extract_text(response)
          Logger.debug("[Architect] Plan response received, parsing... (#{String.length(text)} chars)")

          case parse_plan(text) do
            {:ok, plan_data} ->
              steps = plan_data["plan"] || []
              Logger.debug("[Architect] Parsed plan: #{length(steps)} steps — #{inspect(plan_data, limit: 500)}")

              state =
                if steps != [] do
                  plan_summary = format_plan_summary(plan_data)

                  {:ok, _} =
                    Persistence.save_message(%{
                      session_id: state.id,
                      role: :assistant,
                      content: plan_summary
                    })

                  assistant_msg = %{role: :assistant, content: plan_summary}
                  state = %{state | messages: state.messages ++ [assistant_msg]}
                  broadcast(state.id, {:new_message, state.id, assistant_msg})
                  broadcast(state.id, {:architect_plan, state.id, plan_data})
                  state
                else
                  state
                end

              update_usage(state.id, response)
              {:ok, plan_data, state}

            {:error, reason} ->
              Logger.error("[Architect] Failed to parse plan: #{reason}\n  Raw text: #{String.slice(text, 0, 500)}")
              {:error, "Failed to parse architect plan: #{reason}", state}
          end
        end

      {:error, reason} ->
        Logger.error("[Architect] Plan LLM call returned error: #{inspect(reason)}")
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
  # Executes tools and returns the result as a conversational response.
  defp handle_planning_tool_calls(classified, _response, _provider, _model_id, _req_messages, state, _opts) do
    tool_calls = classified.tool_calls
    tool_names = Enum.map(tool_calls, fn tc -> tc[:name] || tc["name"] end)
    Logger.info("[Architect] Planning tools: #{Enum.join(tool_names, ", ")}")

    results =
      Enum.map(tool_calls, fn tool_call ->
        tool_name = tool_call[:name] || tool_call["name"]
        tool_args = tool_call[:arguments] || tool_call["arguments"] || %{}
        context = %{project_path: state.project_path, session_id: state.id}

        case Jido.AI.ToolAdapter.lookup_action(tool_name, @planning_tools) do
          {:ok, tool_module} ->
            run_and_format_tool(tool_module, tool_args, context)

          {:error, :not_found} ->
            "Error: Planning tool '#{tool_name}' not found"
        end
      end)

    response_text = Enum.join(results, "\n\n")

    {:ok, _} =
      Persistence.save_message(%{
        session_id: state.id,
        role: :assistant,
        content: response_text
      })

    assistant_msg = %{role: :assistant, content: response_text}
    state = %{state | messages: state.messages ++ [assistant_msg]}
    broadcast(state.id, {:new_message, state.id, assistant_msg})

    # Signal that the team was spawned — run/3 should not fall back to conversational
    {:ok, %{"plan" => [], "summary" => response_text, "team_spawned" => true}, state}
  end

  defp conversational_fallback(user_text, state, model) do
    {provider, model_id} = parse_model(model)

    system_prompt = """
    You are Loom, an AI coding assistant. Respond helpfully to the user's request.
    You have access to the project at: #{state.project_path}

    Be concise and direct. If the user is asking to explore or understand the codebase,
    describe what you can see and suggest next steps.
    """

    messages = [
      ReqLLM.Context.system(system_prompt),
      ReqLLM.Context.user(user_text)
    ]

    telemetry_meta = %{session_id: state.id, model: model, architect_phase: :conversational}

    case LoomTelemetry.span_llm_request(telemetry_meta, fn ->
           call_llm(provider, model_id, messages, [])
         end) do
      {:ok, response} ->
        text = extract_text(response)
        Logger.info("[Architect] Conversational fallback responded (#{String.length(text)} chars)")

        {:ok, _} =
          Persistence.save_message(%{session_id: state.id, role: :assistant, content: text})

        assistant_msg = %{role: :assistant, content: text}
        state = %{state | messages: state.messages ++ [assistant_msg]}
        broadcast(state.id, {:new_message, state.id, assistant_msg})
        update_usage(state.id, response)
        {:ok, text, state}

      {:error, reason} ->
        Logger.error("[Architect] Conversational fallback failed: #{inspect(reason)}")
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

    assistant_msg = %{role: :assistant, content: response}
    state = %{state | messages: state.messages ++ [assistant_msg]}
    broadcast(state.id, {:new_message, state.id, assistant_msg})

    {:ok, response, state}
  end

  defp execute_step(step, state, editor_model) do
    file = step["file"]
    action = step["action"]
    details = step["details"]
    description = step["description"]
    Logger.info("[Architect] Executing step: #{action} #{file} — #{description}")

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

    case LoomTelemetry.span_llm_request(telemetry_meta, fn ->
           call_llm(provider, model_id, messages, opts)
         end) do
      {:ok, response} ->
        classified = ReqLLM.Response.classify(response)
        Logger.debug("[Architect] Editor iteration=#{iteration} response_type=#{classified.type}")
        handle_editor_response(classified, response, provider, model_id, messages, state, opts, iteration)

      {:error, reason} ->
        Logger.error("[Architect] Editor LLM call failed iteration=#{iteration}: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  defp handle_editor_response(%{type: :tool_calls} = classified, response, provider, model_id, messages, state, opts, iteration) do
    # Execute tools in the editor context
    assistant_content = classified.text || ""
    tool_calls = classified.tool_calls

    tool_names = Enum.map(tool_calls, fn tc -> tc[:name] || tc["name"] end)
    Logger.info("[Architect] Editor iteration=#{iteration} calling tools: #{Enum.join(tool_names, ", ")}")

    tool_call_msgs =
      Enum.map(tool_calls, fn tc ->
        {tc[:name] || tc["name"], tc[:arguments] || tc["arguments"] || %{},
         id: tc[:id] || tc["id"]}
      end)

    messages =
      messages ++ [ReqLLM.Context.assistant(assistant_content, tool_calls: tool_call_msgs)]

    # Execute each tool call
    {messages, state} =
      Enum.reduce(tool_calls, {messages, state}, fn tool_call, {msgs, st} ->
        tool_name = tool_call[:name]
        tool_args = tool_call[:arguments] || %{}
        tool_call_id = tool_call[:id] || "call_#{Ecto.UUID.generate()}"
        context = %{project_path: st.project_path, session_id: st.id}

        result_text =
          case Jido.AI.ToolAdapter.lookup_action(tool_name, st.tools) do
            {:ok, tool_module} ->
              tool_meta = %{
                tool_name: tool_name,
                session_id: st.id
              }

              LoomTelemetry.span_tool_execute(tool_meta, fn ->
                run_and_format_tool(tool_module, tool_args, context)
              end)

            {:error, :not_found} ->
              Logger.warning("[Architect] Tool not found: #{tool_name}")
              "Error: Tool '#{tool_name}' not found"
          end

        Logger.debug("[Architect] Tool #{tool_name} result: #{String.slice(to_string(result_text), 0, 200)}")
        broadcast(st.id, {:tool_executing, st.id, tool_name})
        broadcast(st.id, {:tool_complete, st.id, tool_name, result_text})

        msgs = msgs ++ [ReqLLM.Context.tool_result(tool_call_id, result_text)]
        {msgs, st}
      end)

    update_usage(state.id, response)
    editor_loop(provider, model_id, messages, state, opts, iteration + 1)
  end

  defp handle_editor_response(%{type: :final_answer} = classified, response, _provider, _model_id, _messages, state, _opts, _iteration) do
    update_usage(state.id, response)
    {:ok, classified.text, state}
  end

  defp build_architect_prompt(state) do
    """
    You are the Architect — a senior software engineer planning code changes.

    Project path: #{state.project_path}

    Your job is to analyze the user's request and decide the best execution strategy.

    ## Strategy Options

    ### 1. File-based edit plan (default for simple/focused tasks)
    Respond with a JSON object containing your edit plan:
    - "summary": brief description of what will be done
    - "plan": array of steps, each with "file", "action" (create/edit/delete), "description", and "details"

    ### 2. Team spawn (for complex, multi-file, or parallelizable tasks)
    Use the `team_spawn` tool to create a team of specialized agents. Do this when:
    - The task involves 5+ files across multiple modules
    - Independent subtasks can be parallelized (e.g. research + implementation)
    - The task benefits from specialized roles (researcher, coder, reviewer, tester)

    After spawning a team, use `team_assign` to delegate subtasks to agents.

    ## Guidelines
    - For simple changes (1-4 files, single concern), prefer a JSON edit plan
    - For complex changes, spawn a team and coordinate via task assignment
    - Be thorough and specific in edit plan "details" — include exact code snippets,
      line references, function signatures, and clear before/after descriptions
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
    classified.text || ""
  end

  defp call_llm(provider, model_id, messages, opts) do
    model_spec = "#{provider}:#{model_id}"
    Logger.debug("[Architect] Calling LLM model=#{model_spec} msg_count=#{length(messages)} opts=#{inspect(Map.keys(Map.new(opts)))}")

    result =
      try do
        ReqLLM.generate_text(model_spec, messages, opts)
      rescue
        e ->
          Logger.error("[Architect] LLM call crashed: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    case result do
      {:ok, _} -> Logger.debug("[Architect] LLM call succeeded for #{model_spec}")
      {:error, reason} -> Logger.error("[Architect] LLM call failed for #{model_spec}: #{inspect(reason)}")
    end

    result
  end

  defp build_req_messages(windowed_messages) do
    Enum.map(windowed_messages, fn msg ->
      case msg.role do
        :system -> ReqLLM.Context.system(msg.content)
        :user -> ReqLLM.Context.user(msg.content)
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

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end

  defp parse_model(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      _ -> {"anthropic", model_string}
    end
  end

  defp resolve_architect_model(opts) do
    # Use the user-selected model (passed via opts from the session).
    # Falls back to config, then a sensible default.
    Keyword.get(opts, :architect_model) ||
      Loom.Config.get(:model, :default) ||
      "anthropic:claude-sonnet-4-6"
  end

  defp resolve_editor_model(opts) do
    # Only use a secondary model when the user has explicitly configured one.
    # If no secondary model is set, fall back to the architect (primary) model
    # so everything runs on the single model the user selected.
    Keyword.get(opts, :editor_model) ||
      Loom.Config.get(:model, :editor) ||
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

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Loom.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end
end
