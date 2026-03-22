defmodule Loomkin.Verification.UpstreamVerifier do
  @moduledoc """
  Ephemeral agent that validates upstream task work products before
  dependent tasks proceed.

  Spawned automatically when a completed task has dependents. Runs
  acceptance checks (compile, test, lint, spec compliance) and returns
  a structured verification result.

  ## Budget and Timeout

  - Budget: 25% of the completing task's budget (or $0.10 default)
  - Timeout: 2 minutes
  - Max iterations: 5

  ## Flow

      Task A completes
        -> UpstreamVerifier spawns (ephemeral, fresh context)
        -> Runs acceptance checks via AcceptanceChecks tool
        -> Returns %{passed: bool, confidence: 0-100, details: map}
        -> If passed: dependent tasks unblock normally
        -> If failed: route to healing pipeline
  """

  require Logger

  alias Loomkin.Teams.Manager

  @default_timeout_ms :timer.minutes(2)
  @default_max_iterations 5

  @verifier_tools [
    Loomkin.Tools.AcceptanceChecks,
    Loomkin.Tools.FileRead,
    Loomkin.Tools.ContentSearch,
    Loomkin.Tools.Shell,
    Loomkin.Tools.LspDiagnostics
  ]

  @doc """
  Start an upstream verification for a completed task.

  ## Options

    * `:team_id` - team the task belongs to (required)
    * `:task` - the completed task struct (required)
    * `:dependent_task_ids` - list of task IDs that depend on this one (required)
    * `:on_complete` - callback `fn result -> ... end` (required)
    * `:budget_usd` - cost ceiling (default: $0.10)
    * `:timeout_ms` - timeout (default: 2 minutes)
    * `:max_iterations` - iteration cap (default: 5)

  Returns `{:ok, pid}` where pid is the Task process.
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    task = Keyword.fetch!(opts, :task)

    Logger.info(
      "[Verification] starting upstream verifier team=#{team_id} task=#{task.id} title=#{task.title}"
    )

    case Task.Supervisor.start_child(Loomkin.Healing.TaskSupervisor, fn ->
           run(opts)
         end) do
      {:ok, pid} ->
        # Set up timeout watchdog
        timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

        Task.Supervisor.start_child(Loomkin.Healing.TaskSupervisor, fn ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            timeout ->
              Logger.warning("[Verification] timed out task=#{task.id}")
              Process.exit(pid, :kill)
          end
        end)

        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          "[Verification] failed to start verifier task=#{task.id} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "Returns the tool modules used by the verifier."
  @spec tools :: [module()]
  def tools, do: @verifier_tools

  # --- Private ---

  defp run(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    task = Keyword.fetch!(opts, :task)
    on_complete = Keyword.fetch!(opts, :on_complete)
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    project_path = resolve_project_path(team_id)
    model = resolve_model(team_id)
    agent_name = "verifier_#{String.slice(task.id, 0, 8)}"

    system_prompt = build_system_prompt(task)
    task_prompt = build_task_prompt(task)

    loop_opts = [
      model: model,
      tools: @verifier_tools,
      system_prompt: system_prompt,
      project_path: project_path,
      agent_name: agent_name,
      team_id: team_id,
      max_iterations: max_iterations,
      on_event: fn event_name, payload ->
        handle_event(team_id, agent_name, event_name, payload)
      end
    ]

    messages = [%{role: :user, content: task_prompt}]

    publish_started(team_id, task)

    result =
      case Loomkin.AgentLoop.run(messages, loop_opts) do
        {:ok, response, _messages, _metadata} ->
          parse_verification_result(response, task)

        {:error, reason, _messages} ->
          Logger.warning("[Verification] agent error task=#{task.id} reason=#{inspect(reason)}")

          %{
            passed: false,
            confidence: 0,
            details: %{error: inspect(reason)},
            task_id: task.id
          }

        {:paused, reason, _messages, _iteration} ->
          Logger.warning("[Verification] agent paused task=#{task.id} reason=#{inspect(reason)}")

          %{
            passed: false,
            confidence: 0,
            details: %{error: "Verifier paused: #{inspect(reason)}"},
            task_id: task.id
          }
      end

    publish_completed(team_id, task, result)

    try do
      on_complete.(result)
    rescue
      e ->
        Logger.error(
          "[Verification] on_complete callback crashed task=#{task.id} error=#{Exception.message(e)}"
        )
    end
  rescue
    e ->
      task_id =
        case Keyword.get(opts, :task) do
          %{id: id} -> id
          _ -> "unknown"
        end

      Logger.error("[Verification] crashed task=#{task_id} error=#{Exception.message(e)}")

      callback = Keyword.get(opts, :on_complete, fn _ -> :ok end)

      try do
        callback.(%{
          passed: false,
          confidence: 0,
          details: %{error: Exception.message(e)},
          task_id: task_id
        })
      rescue
        _ -> :ok
      end
  end

  defp build_system_prompt(task) do
    """
    You are an upstream verification agent. Your job is to validate that a completed
    task's work product meets quality standards before dependent tasks proceed.

    You have access to acceptance check tools. Run the following checks:
    1. syntax — compile the project and check for errors
    2. lint — verify code formatting
    3. tests — run the test suite (focused on changed files if available)

    After running checks, provide your verdict as a structured summary:
    - PASSED or FAILED
    - Confidence score (0-100)
    - Details of any failures

    Task being verified: "#{task.title}"
    Task result: #{task.result || "(no result summary)"}
    Files changed: #{inspect(task.files_changed || [])}

    Be thorough but fast. You have a limited iteration budget.
    """
  end

  defp build_task_prompt(task) do
    """
    Verify the work product of completed task "#{task.title}" (ID: #{task.id}).

    The task owner reported: #{task.result || "(no result)"}
    Files changed: #{inspect(task.files_changed || [])}

    Run acceptance_checks with check_type :syntax, :lint, and :tests.
    Pass task_id "#{task.id}" and files_changed #{inspect(task.files_changed || [])}.

    After all checks complete, summarize your findings in this exact format:
    VERDICT: PASSED or FAILED
    CONFIDENCE: <number 0-100>
    DETAILS: <summary of findings>
    """
  end

  defp parse_verification_result(response, task) do
    text = to_string(response)
    passed = Regex.match?(~r/VERDICT:\s*PASSED/i, text)

    confidence =
      case Regex.run(~r/CONFIDENCE:\s*(\d+)/, text) do
        [_, score] -> String.to_integer(score) |> min(100) |> max(0)
        _ -> if(passed, do: 80, else: 20)
      end

    %{
      passed: passed,
      confidence: confidence,
      details: %{
        response: String.slice(text, 0, 2000),
        task_title: task.title,
        files_changed: task.files_changed || []
      },
      task_id: task.id
    }
  end

  defp resolve_model(team_id) do
    with {:ok, meta} <- Manager.get_team_meta(team_id),
         session_id when not is_nil(session_id) <- meta[:session_id],
         opts when is_list(opts) <- Loomkin.Teams.Role.fast_model_opts(session_id),
         model when is_binary(model) <- Keyword.get(opts, :model) do
      model
    else
      _ -> "anthropic:claude-sonnet-4-6"
    end
  end

  defp resolve_project_path(team_id) do
    Manager.get_team_project_path(team_id)
  end

  defp handle_event(team_id, agent_name, event_name, payload) do
    agent_str = to_string(agent_name)

    case event_name do
      :tool_start ->
        publish_signal(team_id, agent_str, "verification.tool.start", %{
          tool_name: payload[:tool_name] || payload[:name],
          agent_name: agent_str
        })

      :tool_result ->
        publish_signal(team_id, agent_str, "verification.tool.result", %{
          tool_name: payload[:tool_name] || payload[:name],
          agent_name: agent_str
        })

      _ ->
        :ok
    end
  end

  defp publish_started(team_id, task) do
    publish_signal(team_id, "upstream_verifier", "verification.started", %{
      task_id: task.id,
      task_title: task.title
    })
  end

  defp publish_completed(team_id, task, result) do
    publish_signal(team_id, "upstream_verifier", "verification.completed", %{
      task_id: task.id,
      task_title: task.title,
      passed: result.passed,
      confidence: result.confidence
    })
  end

  defp publish_signal(team_id, agent_name, type, payload) do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "team:#{team_id}",
      {:verification_event,
       Map.merge(payload, %{type: type, agent_name: agent_name, team_id: team_id})}
    )
  rescue
    e ->
      Logger.debug("[Verification] publish_signal failed: #{Exception.message(e)}")
      :ok
  end
end
