defmodule Loomkin.MCP.ClientSupervisor do
  @moduledoc """
  Supervisor for the MCP client and its connections.

  Starts empty and reacts to `:config_loaded` PubSub events.
  When MCP servers are configured in `.loomkin.toml`, starts `Loomkin.MCP.Client`
  which manages connections to external MCP servers.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true if there are external MCP servers configured."
  @spec enabled?() :: boolean()
  def enabled? do
    case Loomkin.Config.get(:mcp) do
      %{servers: [_ | _]} -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Loomkin.MCP.DynSupervisor, strategy: :one_for_one},
      Loomkin.MCP.ConfigListener
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Loomkin.MCP.ConfigListener do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Loomkin.Signals.subscribe("system.config.loaded")
    {:ok, %{started: false}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, state), do: handle_info(sig, state)

  def handle_info(%Jido.Signal{type: "system.config.loaded"}, %{started: true} = state) do
    # Already started MCP client — refresh instead of double-starting
    if GenServer.whereis(Loomkin.MCP.Client), do: Loomkin.MCP.Client.refresh()
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{type: "system.config.loaded"}, %{started: false} = state) do
    if Loomkin.MCP.ClientSupervisor.enabled?() do
      DynamicSupervisor.start_child(Loomkin.MCP.DynSupervisor, Loomkin.MCP.Client)

      {:noreply, %{state | started: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
