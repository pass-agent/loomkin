defmodule Loomkin.Healing.EphemeralAgent do
  @moduledoc """
  Lightweight, short-lived agents for diagnosis and repair.

  Ephemeral agents run under `Task.Supervisor` (not as full team GenServers).
  They execute an `AgentLoop` with constrained tool sets, tight iteration limits,
  and structured output requirements, then report results back to the
  `HealingOrchestrator`.
  """

  require Logger

  alias Loomkin.Healing.Orchestrator
  alias Loomkin.Healing.Prompts
  alias Loomkin.Teams.Manager

  # Diagnostician: read-only tools for investigating errors
  @diagnostician_tools [
    Loomkin.Tools.LspDiagnostics,
    Loomkin.Tools.FileRead,
    Loomkin.Tools.ContentSearch,
    Loomkin.Tools.FileSearch,
    Loomkin.Tools.DirectoryList,
    Loomkin.Tools.Shell,
    Loomkin.Tools.DiagnosisReport
  ]

  # Fixer: write-capable tools for applying repairs
  @fixer_tools [
    Loomkin.Tools.FileRead,
    Loomkin.Tools.FileEdit,
    Loomkin.Tools.FileWrite,
    Loomkin.Tools.Shell,
    Loomkin.Tools.Git,
    Loomkin.Tools.LspDiagnostics,
    Loomkin.Tools.FixConfirmation
  ]

  @doc """
  Start an ephemeral healing agent under the healing task supervisor.

  ## Options

    * `:role` - `:diagnostician` or `:fixer` (required)
    * `:team_id` - team the suspended agent belongs to (required)
    * `:session_id` - healing session ID (required)
    * `:classification` - error classification map (diagnostician)
    * `:error_context` - raw error context map (diagnostician)
    * `:retry_context` - previous fix failure reason (diagnostician retry)
    * `:diagnosis` - diagnosis map from diagnostician (fixer)
    * `:max_iterations` - iteration cap (default: 7)
    * `:budget_usd` - cost ceiling (default: 0.20)

  Returns `{:ok, pid}` where pid is the Task process.
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts) do
    role = Keyword.fetch!(opts, :role)
    team_id = Keyword.fetch!(opts, :team_id)
    session_id = Keyword.fetch!(opts, :session_id)

    Logger.info("[Kin:healing] starting ephemeral #{role} session=#{session_id} team=#{team_id}")

    {:ok, pid} =
      Task.Supervisor.start_child(Loomkin.Healing.TaskSupervisor, fn ->
        run(role, opts)
      end)

    {:ok, pid}
  end

  @doc "Returns the tool modules for a given healing role."
  @spec tools_for(:diagnostician | :fixer) :: [module()]
  def tools_for(:diagnostician), do: @diagnostician_tools
  def tools_for(:fixer), do: @fixer_tools

  # -- Private --

  defp run(role, opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    session_id = Keyword.fetch!(opts, :session_id)
    max_iterations = Keyword.get(opts, :max_iterations, 7)

    system_prompt = build_prompt(role, opts)
    tools = tools_for(role)
    model = resolve_model(team_id)
    project_path = resolve_project_path(team_id)
    agent_name = ephemeral_name(role, session_id)

    loop_opts = [
      model: model,
      tools: tools,
      system_prompt: system_prompt,
      project_path: project_path,
      agent_name: agent_name,
      team_id: team_id,
      session_id: session_id,
      max_iterations: max_iterations,
      on_event: fn event_name, payload ->
        handle_event(team_id, agent_name, event_name, payload)
      end
    ]

    task_prompt = build_task_prompt(role, opts)
    messages = [%{role: :user, content: task_prompt}]

    publish_started(team_id, agent_name, role, session_id)

    case Loomkin.AgentLoop.run(messages, loop_opts) do
      {:ok, _response, _messages, _metadata} ->
        Logger.info("[Kin:healing] ephemeral #{role} completed session=#{session_id}")

      {:error, reason, _messages} ->
        Logger.warning(
          "[Kin:healing] ephemeral #{role} failed session=#{session_id} reason=#{inspect(reason)}"
        )

        report_error(role, session_id, reason)

      {:paused, reason, _messages, _iteration} ->
        Logger.warning(
          "[Kin:healing] ephemeral #{role} paused session=#{session_id} reason=#{inspect(reason)}"
        )

        report_error(role, session_id, "Agent paused unexpectedly: #{inspect(reason)}")
    end
  end

  defp build_prompt(:diagnostician, opts), do: Prompts.diagnostician(opts)
  defp build_prompt(:fixer, opts), do: Prompts.fixer(opts)

  defp build_task_prompt(:diagnostician, opts) do
    classification = opts[:classification] || %{}
    error_context = opts[:error_context] || %{}

    error_text =
      error_context[:error_text] ||
        get_in(classification, [:error_context, :error_text]) ||
        "No error text available"

    """
    Investigate and diagnose this error:

    #{error_text}

    Use the available tools to read files, check diagnostics, and search for the root cause.
    When you have identified the problem, submit your findings using the diagnosis_report tool.
    """
  end

  defp build_task_prompt(:fixer, opts) do
    diagnosis = opts[:diagnosis] || %{}

    """
    Apply this fix:

    Root cause: #{diagnosis[:root_cause] || "See system prompt"}
    Suggested fix: #{diagnosis[:suggested_fix] || "See system prompt"}
    Affected files: #{inspect(diagnosis[:affected_files] || [])}

    Read the affected files, apply the minimal fix, verify it works, then submit
    your results using the fix_confirmation tool.
    """
  end

  defp resolve_model(team_id) do
    with {:ok, meta} <- Manager.get_team_meta(team_id),
         session_id when not is_nil(session_id) <- meta[:session_id],
         [model: model] when is_binary(model) <- Loomkin.Teams.Role.fast_model_opts(session_id) do
      model
    else
      _ -> default_model()
    end
  end

  defp default_model, do: "anthropic:claude-sonnet-4-6"

  defp resolve_project_path(team_id) do
    Manager.get_team_project_path(team_id)
  end

  defp ephemeral_name(role, session_id) do
    short_id = String.slice(session_id, 0, 8)
    :"healing_#{role}_#{short_id}"
  end

  defp handle_event(team_id, agent_name, event_name, payload) do
    agent_str = to_string(agent_name)

    case event_name do
      :tool_start ->
        publish_signal(team_id, agent_str, "healing.tool.start", %{
          tool_name: payload[:tool_name] || payload[:name],
          agent_name: agent_str
        })

      :tool_result ->
        publish_signal(team_id, agent_str, "healing.tool.result", %{
          tool_name: payload[:tool_name] || payload[:name],
          agent_name: agent_str
        })

      _ ->
        :ok
    end
  end

  defp publish_started(team_id, agent_name, role, session_id) do
    publish_signal(team_id, to_string(agent_name), "healing.agent.started", %{
      role: to_string(role),
      session_id: session_id
    })
  end

  defp publish_signal(team_id, agent_name, type, payload) do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "team:#{team_id}",
      {:healing_event,
       Map.merge(payload, %{type: type, agent_name: agent_name, team_id: team_id})}
    )
  rescue
    _ -> :ok
  end

  # Diagnostician failure uses dedicated diagnose_failed (S5 fix)
  defp report_error(:diagnostician, session_id, reason) do
    Orchestrator.diagnose_failed(session_id, "Diagnostician failed: #{inspect(reason)}")
  rescue
    _ -> :ok
  end

  defp report_error(:fixer, session_id, reason) do
    Orchestrator.fix_failed(session_id, "Fixer failed: #{inspect(reason)}")
  rescue
    _ -> :ok
  end
end
