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

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "loom:system")
    {:ok, %{started: false}}
  end

  @impl true
  def handle_info({:config_loaded, _config}, %{started: true} = state) do
    # Already started MCP client — refresh instead of double-starting
    if GenServer.whereis(Loomkin.MCP.Client), do: Loomkin.MCP.Client.refresh()
    {:noreply, state}
  end

  def handle_info({:config_loaded, _config}, %{started: false} = state) do
    if Loomkin.MCP.ClientSupervisor.enabled?() do
      case DynamicSupervisor.start_child(Loomkin.MCP.DynSupervisor, Loomkin.MCP.Client) do
        {:ok, _pid} ->
          Logger.info("[MCP] Started MCP client from config")

        {:error, reason} ->
          Logger.warning("[MCP] Failed to start MCP client: #{inspect(reason)}")
      end

      {:noreply, %{state | started: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
