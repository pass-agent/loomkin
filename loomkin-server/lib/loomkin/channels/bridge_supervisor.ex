defmodule Loomkin.Channels.BridgeSupervisor do
  @moduledoc """
  DynamicSupervisor for channel bridge processes.

  Each active binding gets a Bridge GenServer child that bridges
  PubSub events to the channel adapter.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a bridge for the given binding and adapter module."
  def start_bridge(binding, adapter) do
    spec = {Loomkin.Channels.Bridge, binding: binding, adapter: adapter}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "Stop a bridge by its pid."
  def stop_bridge(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc "Stop a bridge for the given channel and channel_id."
  def stop_bridge(channel, channel_id) do
    case Loomkin.Channels.Bridge.lookup(channel, channel_id) do
      {:ok, pid} -> stop_bridge(pid)
      :error -> {:error, :not_found}
    end
  end
end
