defmodule Loomkin.Channels.PermissionRegistry do
  @moduledoc """
  ETS-based registry for pending permission requests.

  When an agent requests permission to execute a tool, the request is
  broadcast on PubSub. This registry captures those requests and assigns
  stable `request_id` values so channel users can approve/deny them
  remotely via `/approve <request_id> once|always|deny`.
  """

  use GenServer

  @table :channel_permission_requests
  @expiry_ms 10 * 60 * 1000
  @cleanup_interval_ms 60 * 1000

  defstruct []

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a pending permission request.

  Returns the generated `request_id` (a short, human-friendly ID).
  """
  @spec register_request(String.t(), String.t(), String.t(), String.t(), String.t()) :: String.t()
  def register_request(team_id, agent_name, tool_name, tool_path, agent_pid_or_ref \\ nil) do
    init_if_needed()

    request_id = short_id()
    now = System.monotonic_time(:millisecond)

    :ets.insert(@table, {
      request_id,
      team_id,
      agent_name,
      tool_name,
      tool_path,
      agent_pid_or_ref,
      now
    })

    request_id
  end

  @doc "List all pending requests, optionally filtered by team_id."
  @spec list_pending(String.t() | nil) :: [map()]
  def list_pending(team_id \\ nil) do
    init_if_needed()
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, tid, _agent, _tool, _path, _ref, ts} ->
      not_expired = now - ts < @expiry_ms
      team_match = team_id == nil || tid == team_id
      not_expired && team_match
    end)
    |> Enum.map(fn {id, tid, agent, tool, path, _ref, ts} ->
      age_s = div(now - ts, 1000)

      %{
        request_id: id,
        team_id: tid,
        agent_name: agent,
        tool_name: tool,
        tool_path: path,
        age_seconds: age_s
      }
    end)
    |> Enum.sort_by(& &1.age_seconds, :desc)
  end

  @doc """
  Resolve a pending permission request.

  `action` is one of: `"once"`, `"always"`, `"deny"`.
  Maps to: `"allow_once"`, `"allow_always"`, `"deny"`.
  """
  @spec resolve_request(String.t(), String.t()) :: :ok | {:error, :not_found} | {:error, :expired}
  def resolve_request(request_id, action) do
    init_if_needed()

    case :ets.lookup(@table, request_id) do
      [] ->
        {:error, :not_found}

      [{^request_id, team_id, agent_name, tool_name, tool_path, _ref, ts}] ->
        now = System.monotonic_time(:millisecond)

        if now - ts >= @expiry_ms do
          :ets.delete(@table, request_id)
          {:error, :expired}
        else
          full_action = normalize_action(action)

          # Find the agent and send the permission response
          case Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, agent_name}) do
            [{pid, _}] ->
              Loomkin.Teams.Agent.permission_response(pid, full_action, tool_name, tool_path)
              :ets.delete(@table, request_id)

              :ok

            [] ->
              :ets.delete(@table, request_id)

              {:error, :not_found}
          end
        end
    end
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    init_if_needed()
    schedule_cleanup()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp init_if_needed do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.each(fn {id, _tid, _agent, _tool, _path, _ref, ts} ->
      if now - ts >= @expiry_ms do
        :ets.delete(@table, id)
      end
    end)
  end

  defp short_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp normalize_action("once"), do: "allow_once"
  defp normalize_action("always"), do: "allow_always"
  defp normalize_action("deny"), do: "deny"
  defp normalize_action(other), do: other
end
