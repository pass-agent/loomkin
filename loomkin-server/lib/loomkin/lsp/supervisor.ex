defmodule Loomkin.LSP.Supervisor do
  @moduledoc """
  Supervises LSP client processes.

  Starts a Registry for named LSP clients and a DynamicSupervisor
  for managing client lifecycles. Starts empty and reacts to
  `:config_loaded` PubSub events to launch configured LSP servers.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start an LSP client for a given server configuration."
  @spec start_client(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_client(opts) do
    DynamicSupervisor.start_child(
      Loomkin.LSP.ClientSupervisor,
      {Loomkin.LSP.Client, opts}
    )
  end

  @doc "Stop an LSP client by name."
  @spec stop_client(String.t()) :: :ok
  def stop_client(name) do
    case Registry.lookup(Loomkin.LSP.Registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Loomkin.LSP.ClientSupervisor, pid)

      [] ->
        :ok
    end
  end

  @doc "List all running LSP client names."
  @spec list_clients() :: [String.t()]
  def list_clients do
    Loomkin.LSP.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Start LSP clients from config.

  Config format:
    [lsp]
    enabled = true
    servers = [
      { name = "elixir-ls", command = "elixir-ls", args = [] }
    ]
  """
  @spec start_from_config() :: :ok
  def start_from_config do
    lsp_config = Loomkin.Config.get(:lsp) || %{}
    root_path = Loomkin.Config.get(:project_path)

    if lsp_config[:enabled] do
      servers = lsp_config[:servers] || []

      Enum.each(servers, fn server ->
        opts =
          [
            name: server[:name] || server["name"],
            command: server[:command] || server["command"],
            args: server[:args] || server["args"] || []
          ] ++ if(root_path, do: [root_path: root_path], else: [])

        start_client(opts)
      end)
    end

    :ok
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Loomkin.LSP.Registry},
      {DynamicSupervisor, name: Loomkin.LSP.ClientSupervisor, strategy: :one_for_one},
      Loomkin.LSP.ConfigListener
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

defmodule Loomkin.LSP.ConfigListener do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Loomkin.Signals.subscribe("system.config.loaded")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, state), do: handle_info(sig, state)

  def handle_info(%Jido.Signal{type: "system.config.loaded"}, state) do
    Loomkin.LSP.Supervisor.start_from_config()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
