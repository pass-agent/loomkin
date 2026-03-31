defmodule Loomkin.Relay.Server.Registry do
  @moduledoc """
  ETS-backed registry for daemon connections and their workspaces.

  Entries are keyed by `{user_id, workspace_id}` and store channel pid,
  machine name, heartbeat time, and workspace metadata.
  """

  @table :loomkin_relay_registry

  @type workspace_entry :: %{
          channel_pid: pid(),
          machine_name: String.t(),
          status: String.t(),
          team_id: String.t() | nil,
          agent_count: non_neg_integer(),
          last_heartbeat: DateTime.t(),
          project_path: String.t(),
          workspace_name: String.t()
        }

  @doc "Create the ETS table. Call once from application.ex."
  @spec init() :: :ok
  def init do
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  @doc "Register a workspace for a user's daemon connection."
  @spec register_workspace(integer(), String.t(), workspace_entry()) :: true
  def register_workspace(user_id, workspace_id, info) do
    :ets.insert(@table, {{user_id, workspace_id}, info})
  end

  @doc "Remove all workspace entries owned by the given channel pid."
  @spec unregister_daemon(pid()) :: :ok
  def unregister_daemon(channel_pid) do
    # ETS partial map matching doesn't work with match_delete.
    # Use select_delete with a proper match spec instead.
    :ets.select_delete(@table, [
      {{:_, %{channel_pid: :"$1"}}, [{:==, :"$1", channel_pid}], [true]}
    ])

    :ok
  end

  @doc """
  Remove all workspace entries for a given user, except those owned by `keep_pid`.

  Used before a new join to evict stale entries from a previous connection.
  """
  @spec evict_stale_workspaces(integer(), pid()) :: :ok
  def evict_stale_workspaces(user_id, keep_pid) do
    :ets.select_delete(@table, [
      {{{:"$1", :_}, %{channel_pid: :"$2"}}, [{:==, :"$1", user_id}, {:"/=", :"$2", keep_pid}],
       [true]}
    ])

    :ok
  end

  @doc "Look up a single workspace entry."
  @spec lookup_workspace(integer(), String.t()) :: {:ok, workspace_entry()} | :error
  def lookup_workspace(user_id, workspace_id) do
    case :ets.lookup(@table, {user_id, workspace_id}) do
      [{_key, info}] -> {:ok, info}
      [] -> :error
    end
  end

  @doc "List all workspace entries for a user."
  @spec list_workspaces(integer()) :: [{String.t(), workspace_entry()}]
  def list_workspaces(user_id) do
    :ets.match_object(@table, {{user_id, :_}, :_})
    |> Enum.map(fn {{_uid, workspace_id}, info} -> {workspace_id, info} end)
  end

  @doc "Touch the last_heartbeat timestamp for a workspace."
  @spec update_heartbeat(integer(), String.t()) :: :ok
  def update_heartbeat(user_id, workspace_id) do
    case :ets.lookup(@table, {user_id, workspace_id}) do
      [{key, info}] ->
        :ets.insert(@table, {key, %{info | last_heartbeat: DateTime.utc_now()}})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Merge changes into an existing workspace entry."
  @spec update_workspace(integer(), String.t(), map()) :: :ok
  def update_workspace(user_id, workspace_id, changes) do
    case :ets.lookup(@table, {user_id, workspace_id}) do
      [{key, info}] ->
        :ets.insert(@table, {key, Map.merge(info, changes)})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Return all entries in the table (for heartbeat scanning)."
  @spec all_entries() :: [{{integer(), String.t()}, workspace_entry()}]
  def all_entries do
    :ets.tab2list(@table)
  end
end
