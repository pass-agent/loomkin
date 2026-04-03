defmodule Loomkin.Teams.CostTracker do
  @moduledoc "Per-agent and per-team cost tracking via ETS."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.TeamTask
  alias Loomkin.Teams.Pricing

  @table :loomkin_cost_tracker
  @max_call_history 500
  @max_escalations 500

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  # Cost is stored as integer microdollars (cost * 1_000_000) for atomic update_counter.
  @cost_scale 1_000_000

  @doc "Record usage for an agent within a team."
  def record_usage(team_id, agent_name, %{} = usage) do
    init_if_needed()
    key = {:agent, team_id, agent_name}

    input = usage[:input_tokens] || 0
    output = usage[:output_tokens] || 0
    cost_micros = round(resolve_cost(usage) * @cost_scale)

    try do
      # Atomic increment: {key, input_tokens, output_tokens, cost_micros, requests, last_model}
      # Positions:         1     2              3               4             5        6
      :ets.update_counter(@table, key, [{2, input}, {3, output}, {4, cost_micros}, {5, 1}])
    catch
      :error, :badarg ->
        # Key doesn't exist — initialize as tuple
        :ets.insert(@table, {key, input, output, cost_micros, 1, usage[:model]})
    end

    # Update last_model separately (non-numeric field)
    if usage[:model] do
      case :ets.lookup(@table, key) do
        [{^key, in_t, out_t, c, r, _old_model}] ->
          :ets.insert(@table, {key, in_t, out_t, c, r, usage[:model]})

        _ ->
          :ok
      end
    end

    :ok
  end

  @doc """
  Record a single LLM call with full detail for an agent.

  `call_data` should include: model, input_tokens, output_tokens, cost, task_id,
  duration_ms, timestamp.
  """
  def record_call(team_id, agent_name, %{} = call_data) do
    init_if_needed()
    key = {:calls, team_id, agent_name}

    call =
      call_data
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> Map.put_new_lazy(:cost, fn ->
        Pricing.calculate_cost(
          call_data[:model] || "",
          call_data[:input_tokens] || 0,
          call_data[:output_tokens] || 0
        )
      end)

    current = lookup_or_default(key, [])
    :ets.insert(@table, {key, Enum.take([call | current], @max_call_history)})
    :ok
  end

  @doc "Get the list of per-call records for an agent (newest first)."
  def get_call_history(team_id, agent_name) do
    init_if_needed()
    key = {:calls, team_id, agent_name}
    lookup_or_default(key, [])
  end

  @doc "Get accumulated usage for a specific agent."
  def get_agent_usage(team_id, agent_name) do
    init_if_needed()
    key = {:agent, team_id, agent_name}

    case :ets.lookup(@table, key) do
      [{^key, in_t, out_t, cost_micros, reqs, model}] ->
        %{
          input_tokens: in_t,
          output_tokens: out_t,
          cost: cost_micros / @cost_scale,
          requests: reqs,
          last_model: model
        }

      _ ->
        default_agent_usage()
    end
  end

  @doc "Get per-agent usage breakdown for a team."
  def get_team_usage(team_id) do
    init_if_needed()

    :ets.tab2list(@table)
    |> Enum.filter(fn
      {{:agent, ^team_id, _name}, _, _, _, _, _} -> true
      _ -> false
    end)
    |> Map.new(fn {{:agent, ^team_id, name}, in_t, out_t, cost_micros, reqs, model} ->
      {name,
       %{
         input_tokens: in_t,
         output_tokens: out_t,
         cost: cost_micros / @cost_scale,
         requests: reqs,
         last_model: model
       }}
    end)
  end

  @doc "Persist cost and token totals to a TeamTask record in the database."
  def persist_task_cost(task_id, cost_usd, tokens_used) do
    case Repo.get(TeamTask, task_id) do
      nil ->
        {:error, :not_found}

      task ->
        task
        |> TeamTask.changeset(%{cost_usd: cost_usd, tokens_used: tokens_used})
        |> Repo.update()
    end
  end

  @doc "Aggregate cost_usd and tokens_used from all team_tasks for a team."
  def team_cost_summary(team_id) do
    query =
      from t in TeamTask,
        where: t.team_id == ^team_id,
        select: %{
          total_cost_usd: coalesce(sum(t.cost_usd), 0),
          total_tokens: coalesce(sum(t.tokens_used), 0),
          task_count: count(t.id)
        }

    Repo.one(query) || %{total_cost_usd: Decimal.new(0), total_tokens: 0, task_count: 0}
  end

  @doc "Record an escalation event."
  def record_escalation(team_id, agent_name, from_model, to_model) do
    init_if_needed()
    key = {:escalations, team_id}

    current = lookup_or_default(key, [])

    entry = %{
      agent: agent_name,
      from: from_model,
      to: to_model,
      at: DateTime.utc_now()
    }

    :ets.insert(@table, {key, Enum.take([entry | current], @max_escalations)})
    :ok
  end

  @doc "List all escalation events for a team."
  def list_escalations(team_id) do
    init_if_needed()
    key = {:escalations, team_id}
    lookup_or_default(key, []) |> Enum.reverse()
  end

  @doc "Reset all tracking data for a team."
  def reset_team(team_id) do
    init_if_needed()

    :ets.tab2list(@table)
    |> Enum.each(fn
      {{:agent, ^team_id, _name}, _, _, _, _, _} = entry -> :ets.delete(@table, elem(entry, 0))
      {{:calls, ^team_id, _name}, _} = entry -> :ets.delete(@table, elem(entry, 0))
      {{:escalations, ^team_id}, _} -> :ets.delete(@table, {:escalations, team_id})
      _ -> :ok
    end)

    :ok
  end

  # -- Private --

  defp init_if_needed do
    if :ets.whereis(@table) == :undefined do
      init()
    end
  end

  defp lookup_or_default(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp default_agent_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cost: 0,
      requests: 0,
      last_model: nil
    }
  end

  # Resolve cost: use provided cost, or auto-calculate from model + tokens via Pricing
  defp resolve_cost(usage) do
    case usage[:cost] do
      cost when is_number(cost) and cost > 0 ->
        cost

      _ ->
        model = usage[:model]
        input = usage[:input_tokens] || 0
        output = usage[:output_tokens] || 0

        if model && (input > 0 || output > 0) do
          Pricing.calculate_cost(model, input, output)
        else
          0
        end
    end
  end
end
