defmodule Loomkin.Relay.Server.HeartbeatMonitor do
  @moduledoc """
  Periodically scans the relay registry for stale daemon connections
  (no heartbeat within the threshold) and removes them.
  """

  use GenServer

  alias Loomkin.Relay.Server.Registry

  require Logger

  @check_interval_ms Application.compile_env(
                       :loomkin,
                       [__MODULE__, :check_interval_ms],
                       10_000
                     )
  @stale_threshold_seconds Application.compile_env(
                             :loomkin,
                             [__MODULE__, :stale_threshold_seconds],
                             30
                           )

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check_heartbeats, state) do
    now = DateTime.utc_now()

    Registry.all_entries()
    |> Enum.each(fn {{user_id, workspace_id}, info} ->
      age = DateTime.diff(now, info.last_heartbeat, :second)

      if age > @stale_threshold_seconds do
        Logger.warning(
          "Stale daemon detected: user=#{user_id} workspace=#{workspace_id} " <>
            "machine=#{info.machine_name} last_heartbeat=#{age}s ago — removing"
        )

        Registry.unregister_daemon(info.channel_pid)
        Process.exit(info.channel_pid, :stale_heartbeat)
      end
    end)

    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_heartbeats, @check_interval_ms)
  end
end
