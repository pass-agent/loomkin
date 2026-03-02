defmodule Loomkin.Teams.TableRegistry do
  @moduledoc "Maps team IDs to unnamed ETS table references, avoiding atom leaks."

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create an unnamed ETS table for a team. Returns the table reference."
  def create_table(team_id) do
    GenServer.call(__MODULE__, {:create, team_id})
  end

  @doc "Get the ETS table reference for a team. Returns {:ok, ref} or :error."
  def get_table(team_id) do
    GenServer.call(__MODULE__, {:get, team_id})
  end

  @doc "Get the ETS table reference, raising if not found."
  def get_table!(team_id) do
    case get_table(team_id) do
      {:ok, ref} -> ref
      :error -> raise ArgumentError, "No ETS table for team #{team_id}"
    end
  end

  @doc "Delete the ETS table for a team."
  def delete_table(team_id) do
    GenServer.call(__MODULE__, {:delete, team_id})
  end

  # Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{tables: %{}}}
  end

  @impl true
  def handle_call({:create, team_id}, _from, state) do
    ref = :ets.new(:loomkin_team, [:public, :set, read_concurrency: true])
    tables = Map.put(state.tables, team_id, ref)
    {:reply, {:ok, ref}, %{state | tables: tables}}
  end

  def handle_call({:get, team_id}, _from, state) do
    case Map.fetch(state.tables, team_id) do
      {:ok, ref} -> {:reply, {:ok, ref}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:delete, team_id}, _from, state) do
    case Map.pop(state.tables, team_id) do
      {nil, _tables} ->
        {:reply, :ok, state}

      {ref, remaining} ->
        try do
          :ets.delete(ref)
        rescue
          ArgumentError -> :ok
        end

        {:reply, :ok, %{state | tables: remaining}}
    end
  end
end
