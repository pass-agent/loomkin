defmodule Loomkin.Teams.TableRegistry do
  @moduledoc """
  Maps team IDs to unnamed ETS table references, avoiding atom leaks.

  Uses a named ETS meta-table (`:loomkin_table_registry`) to persist the
  team_id → ETS ref mapping. Both the meta-table and individual team tables
  use `{:heir, supervisor_pid}` so they survive GenServer restarts — the
  supervisor inherits ownership when this process dies and we reclaim it
  on init.

  All tables are `:public`, so reads work regardless of ownership.
  """

  use GenServer

  require Logger

  @meta_table :loomkin_table_registry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create an unnamed ETS table for a team. Returns the table reference."
  def create_table(team_id) do
    GenServer.call(__MODULE__, {:create, team_id})
  end

  @doc "Get the ETS table reference for a team. Returns {:ok, ref} or {:error, :not_found}."
  def get_table(team_id) do
    # Direct ETS lookup — no GenServer call needed for reads.
    # This is safe because both the meta-table and team tables are :public.
    try do
      case :ets.lookup(@meta_table, team_id) do
        [{^team_id, ref}] ->
          # Verify the team table still exists
          case :ets.info(ref, :size) do
            :undefined -> {:error, :not_found}
            _ -> {:ok, ref}
          end

        [] ->
          {:error, :not_found}
      end
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @doc "Get the ETS table reference, raising if not found."
  def get_table!(team_id) do
    case get_table(team_id) do
      {:ok, ref} -> ref
      {:error, :not_found} -> raise ArgumentError, "No ETS table for team #{team_id}"
    end
  end

  @doc "Delete the ETS table for a team."
  def delete_table(team_id) do
    GenServer.call(__MODULE__, {:delete, team_id})
  end

  @doc "List all registered team IDs."
  def list_teams do
    try do
      :ets.tab2list(@meta_table) |> Enum.map(fn {team_id, _ref} -> team_id end)
    rescue
      ArgumentError -> []
    end
  end

  # Callbacks

  @impl true
  def init(_opts) do
    heir = heir_spec()

    case :ets.whereis(@meta_table) do
      :undefined ->
        opts = [:named_table, :public, :set, {:read_concurrency, true}] ++ heir
        :ets.new(@meta_table, opts)

        Logger.debug("[TableRegistry] Created meta-table")

      _ref ->
        # Meta-table survived restart (heir kept it alive).
        # Prune any team entries whose ETS tables no longer exist.
        prune_dead_tables()
        Logger.info("[TableRegistry] Reclaimed meta-table after restart")
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, team_id}, _from, state) do
    opts = [:public, :set, {:read_concurrency, true}] ++ heir_spec()
    ref = :ets.new(:loomkin_team, opts)

    :ets.insert(@meta_table, {team_id, ref})
    {:reply, {:ok, ref}, state}
  end

  def handle_call({:delete, team_id}, _from, state) do
    case :ets.lookup(@meta_table, team_id) do
      [{^team_id, ref}] ->
        :ets.delete(@meta_table, team_id)

        try do
          :ets.delete(ref)
        rescue
          ArgumentError -> :ok
        end

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from_pid, _data}, state) do
    # Received ownership of an ETS table from a dying process (heir callback).
    {:noreply, state}
  end

  # Build heir spec pointing to our supervisor so tables survive our restart.
  defp heir_spec do
    case Process.whereis(Loomkin.Teams.Supervisor) do
      nil -> []
      pid -> [{:heir, pid, :table_registry}]
    end
  end

  # Remove entries from the meta-table where the team ETS table no longer exists.
  defp prune_dead_tables do
    for {team_id, ref} <- :ets.tab2list(@meta_table) do
      case :ets.info(ref, :size) do
        :undefined ->
          Logger.warning("[TableRegistry] Pruning dead table for team=#{team_id}")
          :ets.delete(@meta_table, team_id)

        _ ->
          :ok
      end
    end
  end
end
