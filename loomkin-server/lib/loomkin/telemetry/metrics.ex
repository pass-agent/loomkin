defmodule Loomkin.Telemetry.Metrics do
  @moduledoc """
  ETS-backed real-time metrics aggregation for Loomkin telemetry events.

  Tracks per-session and global metrics:
  - Total tokens (prompt + completion)
  - Total cost
  - Message count
  - Tool call count and durations
  - Model usage breakdown

  Also handles team/agent-scoped events:
  - Team LLM request tracking (routed to CostTracker)
  - Model escalation events
  - Budget warning broadcasts
  """

  alias Loomkin.Teams.CostTracker

  use GenServer

  @table :loomkin_telemetry_metrics

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get metrics for a specific session."
  def session_metrics(session_id) do
    case :ets.lookup(@table, {:session, session_id}) do
      [{_, metrics}] -> metrics
      [] -> default_session_metrics()
    end
  rescue
    ArgumentError -> default_session_metrics()
  end

  @doc "Get global aggregate metrics."
  def global_metrics do
    case :ets.lookup(@table, :global) do
      [{_, metrics}] -> metrics
      [] -> default_global_metrics()
    end
  rescue
    ArgumentError -> default_global_metrics()
  end

  @doc "Get model usage breakdown (map of model => request count)."
  def model_breakdown do
    case :ets.lookup(@table, :models) do
      [{_, breakdown}] -> breakdown
      [] -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  @doc "Get tool usage stats (map of tool_name => %{count, total_duration_ms, successes})."
  def tool_stats do
    case :ets.lookup(@table, :tools) do
      [{_, stats}] -> stats
      [] -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  @doc "Get per-agent usage breakdown for a team. Delegates to CostTracker."
  def team_metrics(team_id) do
    CostTracker.get_team_usage(team_id)
  end

  @doc "Get usage metrics for a specific agent within a team. Delegates to CostTracker."
  def agent_metrics(team_id, agent_name) do
    CostTracker.get_agent_usage(team_id, agent_name)
  end

  @doc "Get all session summaries for the dashboard."
  def all_sessions do
    :ets.match_object(@table, {{:session, :_}, :_})
    |> Enum.map(fn {{:session, sid}, metrics} -> Map.put(metrics, :session_id, sid) end)
    |> Enum.sort_by(& &1.last_activity, {:desc, DateTime})
  rescue
    ArgumentError -> []
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :ets.insert(table, {:global, default_global_metrics()})
    :ets.insert(table, {:models, %{}})
    :ets.insert(table, {:tools, %{}})

    attach_handlers()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:update_session, session_id, fun}, state) do
    key = {:session, session_id}

    current =
      case :ets.lookup(@table, key) do
        [{_, m}] -> m
        [] -> default_session_metrics()
      end

    :ets.insert(@table, {key, fun.(current)})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_global, fun}, state) do
    current =
      case :ets.lookup(@table, :global) do
        [{_, g}] -> g
        [] -> default_global_metrics()
      end

    :ets.insert(@table, {:global, fun.(current)})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_map, map_key, entry_key, fun, default}, state) do
    current_map =
      case :ets.lookup(@table, map_key) do
        [{_, m}] -> m
        [] -> %{}
      end

    new_value =
      case Map.get(current_map, entry_key) do
        nil -> default
        existing -> fun.(existing)
      end

    :ets.insert(@table, {map_key, Map.put(current_map, entry_key, new_value)})
    {:noreply, state}
  end

  defp attach_handlers do
    handlers = [
      {"loomkin-metrics-llm-stop", [:loomkin, :llm, :request, :stop],
       &__MODULE__.handle_llm_stop/4},
      {"loomkin-metrics-tool-stop", [:loomkin, :tool, :execute, :stop],
       &__MODULE__.handle_tool_stop/4},
      {"loomkin-metrics-session-message", [:loomkin, :session, :message],
       &__MODULE__.handle_session_message/4},
      {"loomkin-metrics-decision-logged", [:loomkin, :decision, :logged],
       &__MODULE__.handle_decision_logged/4},
      {"loomkin-metrics-team-llm-stop", [:loomkin, :team, :llm, :request, :stop],
       &__MODULE__.handle_team_llm_stop/4},
      {"loomkin-metrics-team-escalation", [:loomkin, :team, :escalation],
       &__MODULE__.handle_team_escalation/4},
      {"loomkin-metrics-team-budget-warning", [:loomkin, :team, :budget, :warning],
       &__MODULE__.handle_team_budget_warning/4}
    ]

    for {id, event, fun} <- handlers do
      :telemetry.detach(id)
      :telemetry.attach(id, event, fun, nil)
    end
  end

  # --- Telemetry Handlers (called in the emitting process) ---

  def handle_llm_stop(_event, measurements, metadata, _config) do
    session_id = metadata[:session_id]
    model = metadata[:model]
    input = metadata[:input_tokens] || 0
    output = metadata[:output_tokens] || 0
    cost = metadata[:total_cost] || 0
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    # Update session metrics
    update_session(session_id, fn m ->
      %{
        m
        | prompt_tokens: m.prompt_tokens + input,
          completion_tokens: m.completion_tokens + output,
          cost_usd: m.cost_usd + cost,
          llm_requests: m.llm_requests + 1,
          total_latency_ms: m.total_latency_ms + duration_ms,
          last_activity: DateTime.utc_now()
      }
    end)

    # Update global
    update_global(fn g ->
      %{
        g
        | total_tokens: g.total_tokens + input + output,
          total_cost: g.total_cost + cost,
          total_requests: g.total_requests + 1
      }
    end)

    # Update model breakdown
    update_map(:models, model || "unknown", fn count -> count + 1 end, 1)

    broadcast_update()
  end

  def handle_tool_stop(_event, measurements, metadata, _config) do
    session_id = metadata[:session_id]
    tool_name = metadata[:tool_name] || "unknown"
    success = metadata[:success] || false
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    # Update session tool count
    update_session(session_id, fn m ->
      %{m | tool_calls: m.tool_calls + 1, last_activity: DateTime.utc_now()}
    end)

    # Update tool stats
    update_map(
      :tools,
      tool_name,
      fn stats ->
        %{
          stats
          | count: stats.count + 1,
            total_duration_ms: stats.total_duration_ms + duration_ms,
            successes: stats.successes + if(success, do: 1, else: 0)
        }
      end,
      %{count: 1, total_duration_ms: duration_ms, successes: if(success, do: 1, else: 0)}
    )

    broadcast_update()
  end

  def handle_session_message(_event, _measurements, metadata, _config) do
    session_id = metadata[:session_id]
    role = metadata[:role]

    update_session(session_id, fn m ->
      messages =
        case role do
          :user -> %{m.messages | user: m.messages.user + 1}
          :assistant -> %{m.messages | assistant: m.messages.assistant + 1}
          :tool -> %{m.messages | tool: m.messages.tool + 1}
          _ -> m.messages
        end

      %{m | messages: messages, last_activity: DateTime.utc_now()}
    end)
  end

  def handle_decision_logged(_event, _measurements, metadata, _config) do
    session_id = metadata[:session_id]

    update_session(session_id, fn m ->
      %{m | decisions: m.decisions + 1, last_activity: DateTime.utc_now()}
    end)
  end

  # --- Team/Agent Telemetry Handlers ---

  def handle_team_llm_stop(_event, _measurements, metadata, _config) do
    team_id = metadata[:team_id]
    agent_name = metadata[:agent_name]
    model = metadata[:model]
    input_tokens = metadata[:input_tokens] || 0
    output_tokens = metadata[:output_tokens] || 0
    cost = metadata[:cost] || 0

    # NOTE: CostTracker.record_usage is called directly in Agent.track_usage/2.
    # This handler only broadcasts for LiveView dashboards — no double-counting.

    broadcast_team(
      team_id,
      {:team_llm_stop,
       %{
         team_id: team_id,
         agent_name: agent_name,
         model: model,
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         cost: cost
       }}
    )
  end

  def handle_team_escalation(_event, _measurements, metadata, _config) do
    team_id = metadata[:team_id]
    agent_name = metadata[:agent_name]
    from_model = metadata[:from_model]
    to_model = metadata[:to_model]

    # NOTE: CostTracker.record_escalation is called directly in Agent.attempt_escalation/2.
    # This handler only broadcasts for LiveView dashboards — no double-counting.

    broadcast_team(
      team_id,
      {:team_escalation,
       %{
         team_id: team_id,
         agent_name: agent_name,
         from_model: from_model,
         to_model: to_model
       }}
    )
  end

  def handle_team_budget_warning(_event, _measurements, metadata, _config) do
    team_id = metadata[:team_id]
    spent = metadata[:spent]
    limit = metadata[:limit]
    threshold = metadata[:threshold]

    broadcast_team(
      team_id,
      {:team_budget_warning,
       %{
         team_id: team_id,
         spent: spent,
         limit: limit,
         threshold: threshold
       }}
    )
  end

  # --- Internal helpers ---

  defp update_session(nil, _fun), do: :ok

  defp update_session(session_id, fun) do
    GenServer.cast(__MODULE__, {:update_session, session_id, fun})
  end

  defp update_global(fun) do
    GenServer.cast(__MODULE__, {:update_global, fun})
  end

  defp update_map(map_key, entry_key, fun, default) do
    GenServer.cast(__MODULE__, {:update_map, map_key, entry_key, fun, default})
  end

  defp default_session_metrics do
    %{
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: 0,
      llm_requests: 0,
      tool_calls: 0,
      total_latency_ms: 0,
      decisions: 0,
      messages: %{user: 0, assistant: 0, tool: 0},
      last_activity: DateTime.utc_now()
    }
  end

  defp default_global_metrics do
    %{
      total_tokens: 0,
      total_cost: 0,
      total_requests: 0
    }
  end

  defp broadcast_update do
    signal = Loomkin.Signals.System.MetricsUpdated.new!()
    Loomkin.Signals.publish(signal)
  rescue
    _e ->
      :ok
  end

  defp broadcast_team(_team_id, {:team_llm_stop, payload}) do
    signal =
      Loomkin.Signals.Team.LlmStop.new!(%{team_id: payload.team_id}, subject: payload.agent_name)

    Loomkin.Signals.publish(%{signal | data: Map.merge(signal.data, payload)})
  rescue
    _e ->
      :ok
  end

  defp broadcast_team(_team_id, {:team_escalation, payload}) do
    signal =
      Loomkin.Signals.Agent.Escalation.new!(%{
        agent_name: payload.agent_name,
        team_id: payload.team_id,
        from_model: payload.from_model,
        to_model: payload.to_model
      })

    Loomkin.Signals.publish(signal)
  rescue
    _e ->
      :ok
  end

  defp broadcast_team(_team_id, {:team_budget_warning, payload}) do
    signal = Loomkin.Signals.Team.BudgetWarning.new!(%{team_id: payload.team_id})
    Loomkin.Signals.publish(%{signal | data: Map.merge(signal.data, payload)})
  rescue
    _e ->
      :ok
  end
end
