defmodule Loomkin.Teams.Context do
  @moduledoc "Per-team shared state via ETS. Region-level file locking, discoveries, agent roster."

  # Claims auto-expire after 5 minutes
  @claim_ttl_ms 5 * 60 * 1000

  # -- Agent Roster --

  def register_agent(team_id, name, %{role: _, status: _} = info) do
    :ets.insert(team_table(team_id), {{:agent, name}, info})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def update_agent_status(team_id, name, status) do
    case get_agent(team_id, name) do
      {:ok, info} ->
        :ets.insert(team_table(team_id), {{:agent, name}, %{info | status: status}})
        :ok

      :error ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  def get_agent(team_id, name) do
    case :ets.lookup(team_table(team_id), {:agent, name}) do
      [{{:agent, ^name}, info}] -> {:ok, info}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def list_agents(team_id) do
    :ets.match_object(team_table(team_id), {{:agent, :_}, :_})
    |> Enum.map(fn {{:agent, name}, info} -> Map.put(info, :name, name) end)
  rescue
    ArgumentError -> []
  end

  # -- Shared Discoveries --

  def add_discovery(team_id, %{from: _, type: _, content: _} = discovery) do
    seq = System.unique_integer([:monotonic, :positive])
    discovery = Map.put(discovery, :timestamp, System.monotonic_time(:millisecond))
    :ets.insert(team_table(team_id), {{:discovery, seq}, discovery})
    :ok
  rescue
    ArgumentError -> {:error, :no_team_table}
  end

  def list_discoveries(team_id) do
    :ets.match_object(team_table(team_id), {{:discovery, :_}, :_})
    |> Enum.sort_by(fn {{:discovery, seq}, _} -> seq end)
    |> Enum.map(fn {_key, discovery} -> discovery end)
  rescue
    ArgumentError -> []
  end

  def list_discoveries(team_id, type: type) do
    list_discoveries(team_id)
    |> Enum.filter(&(&1.type == type))
  end

  # -- Region-Level Locking --

  def claim_region(team_id, agent_name, path, region) do
    table = team_table(team_id)

    claim = %{
      agent: agent_name,
      path: path,
      region: region,
      claimed_at: System.monotonic_time(:millisecond)
    }

    # Try atomic insert first — succeeds if no claim exists for this agent+path
    case :ets.insert_new(table, {{:claim, path, agent_name}, claim}) do
      true ->
        # Inserted; now check for conflicts with other agents
        existing = list_claims(team_id, path)

        conflict =
          Enum.find(existing, fn c ->
            c.agent != agent_name and regions_overlap?(c.region, region)
          end)

        case conflict do
          nil ->
            :ok

          other ->
            # Roll back our claim and report conflict
            :ets.delete(table, {:claim, path, agent_name})
            {:conflict, other.agent, other.region}
        end

      false ->
        # Agent already has a claim on this path — update it
        :ets.insert(table, {{:claim, path, agent_name}, claim})

        existing = list_claims(team_id, path)

        conflict =
          Enum.find(existing, fn c ->
            c.agent != agent_name and regions_overlap?(c.region, region)
          end)

        case conflict do
          nil -> :ok
          other -> {:conflict, other.agent, other.region}
        end
    end
  rescue
    ArgumentError -> {:error, :no_team_table}
  end

  def release_region(team_id, agent_name, path) do
    :ets.delete(team_table(team_id), {:claim, path, agent_name})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def list_claims(team_id, path) do
    now = System.monotonic_time(:millisecond)

    :ets.match_object(team_table(team_id), {{:claim, path, :_}, :_})
    |> Enum.map(fn {_key, claim} -> claim end)
    |> Enum.filter(fn claim -> now - claim.claimed_at < @claim_ttl_ms end)
  rescue
    ArgumentError -> []
  end

  def list_all_claims(team_id) do
    now = System.monotonic_time(:millisecond)

    :ets.match_object(team_table(team_id), {{:claim, :_, :_}, :_})
    |> Enum.map(fn {_key, claim} -> claim end)
    |> Enum.filter(fn claim -> now - claim.claimed_at < @claim_ttl_ms end)
  rescue
    ArgumentError -> []
  end

  def broadcast_intent(team_id, agent_name, path, description) do
    Loomkin.Teams.Comms.broadcast(team_id, {:intent, agent_name, path, description})
  end

  # -- Task Summaries (denormalized cache) --

  def cache_task(team_id, task_id, %{title: _, status: _, owner: _} = task) do
    :ets.insert(team_table(team_id), {{:task, task_id}, task})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def get_cached_task(team_id, task_id) do
    case :ets.lookup(team_table(team_id), {:task, task_id}) do
      [{{:task, ^task_id}, task}] -> {:ok, task}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def list_cached_tasks(team_id) do
    :ets.match_object(team_table(team_id), {{:task, :_}, :_})
    |> Enum.map(fn {{:task, id}, task} -> Map.put(task, :id, id) end)
  rescue
    ArgumentError -> []
  end

  # -- Private helpers --

  defp team_table(team_id), do: Loomkin.Teams.TableRegistry.get_table!(team_id)

  defp regions_overlap?(:whole_file, _), do: true
  defp regions_overlap?(_, :whole_file), do: true
  defp regions_overlap?({:symbol, _}, _), do: true
  defp regions_overlap?(_, {:symbol, _}), do: true

  defp regions_overlap?({:lines, s1, e1}, {:lines, s2, e2}) do
    s1 <= e2 and s2 <= e1
  end

  defp regions_overlap?(_, _), do: false
end
