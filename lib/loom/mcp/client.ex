defmodule Loom.MCP.Client do
  @moduledoc """
  Connects to external MCP servers and makes their tools available to Loom.

  Each configured MCP server (in `.loom.toml`) gets an endpoint registered
  with jido_mcp's ClientPool. Tools discovered from those servers are converted
  into Jido.Action proxy modules and registered with `Loom.Tools.Registry`
  via the dynamic tool list.

  Configuration via `.loom.toml`:

      [mcp]
      servers = [
        { name = "tidewave", command = "mix", args = ["tidewave.server"] },
        { name = "hexdocs", url = "http://localhost:3001/sse" }
      ]
  """

  use GenServer

  require Logger

  @sync_timeout 15_000

  defstruct endpoints: %{}, tools: %{}

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all external MCP tools as a flat list of proxy action modules."
  @spec external_tools() :: [module()]
  def external_tools do
    GenServer.call(__MODULE__, :external_tools, @sync_timeout)
  catch
    :exit, _ -> []
  end

  @doc "Returns tool definitions (ReqLLM.Tool structs) for all external MCP tools."
  @spec external_tool_definitions() :: [ReqLLM.Tool.t()]
  def external_tool_definitions do
    tools = external_tools()

    if tools == [] do
      []
    else
      Jido.AI.ToolAdapter.from_actions(tools)
    end
  catch
    _ -> []
  end

  @doc "Lists discovered tools for a specific endpoint."
  @spec tools_for(atom()) :: [module()]
  def tools_for(endpoint_id) do
    GenServer.call(__MODULE__, {:tools_for, endpoint_id}, @sync_timeout)
  catch
    :exit, _ -> []
  end

  @doc "Refreshes tools from all connected endpoints."
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Refreshes tools from a specific endpoint."
  @spec refresh(atom()) :: :ok
  def refresh(endpoint_id) do
    GenServer.cast(__MODULE__, {:refresh, endpoint_id})
  end

  @doc "Returns the status of all endpoints."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status, @sync_timeout)
  catch
    :exit, _ -> %{}
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    # Defer connection setup to allow supervision tree to complete
    send(self(), :connect)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:connect, state) do
    servers = get_server_configs()

    state =
      Enum.reduce(servers, state, fn server_config, acc ->
        connect_server(server_config, acc)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:external_tools, _from, state) do
    tools =
      state.tools
      |> Map.values()
      |> List.flatten()

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:tools_for, endpoint_id}, _from, state) do
    {:reply, Map.get(state.tools, endpoint_id, []), state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    statuses =
      Map.new(state.endpoints, fn {id, config} ->
        endpoint_status =
          try do
            Jido.MCP.endpoint_status(id)
          rescue
            _ -> {:error, :not_connected}
          end

        {id, %{config: config, status: endpoint_status, tool_count: length(Map.get(state.tools, id, []))}}
      end)

    {:reply, statuses, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    state =
      Enum.reduce(state.endpoints, state, fn {endpoint_id, _config}, acc ->
        sync_tools(endpoint_id, acc)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:refresh, endpoint_id}, state) do
    state = sync_tools(endpoint_id, state)
    {:noreply, state}
  end

  # --- Private ---

  defp get_server_configs do
    case Loom.Config.get(:mcp) do
      %{servers: servers} when is_list(servers) -> servers
      _ -> []
    end
  end

  defp connect_server(server_config, state) do
    name = server_config[:name] || server_config["name"]

    unless name do
      Logger.warning("[MCP Client] Server config missing :name, skipping: #{inspect(server_config)}")
      state
    else
      endpoint_id = String.to_atom(name)
      transport = build_transport(server_config)

      endpoint_config = %{
        transport: transport,
        client_info: %{name: "loom", version: "0.1.0"},
        capabilities: %{}
      }

      # Register endpoint in application env for jido_mcp
      existing = Application.get_env(:jido_mcp, :endpoints, [])

      unless Keyword.has_key?(existing, endpoint_id) do
        Application.put_env(:jido_mcp, :endpoints, Keyword.put(existing, endpoint_id, endpoint_config))
      end

      state = %{state | endpoints: Map.put(state.endpoints, endpoint_id, server_config)}

      # Try to sync tools from this endpoint
      sync_tools(endpoint_id, state)
    end
  end

  defp build_transport(config) do
    cond do
      config[:url] || config["url"] ->
        url = config[:url] || config["url"]
        {:streamable_http, url: url}

      config[:command] || config["command"] ->
        command = config[:command] || config["command"]
        args = config[:args] || config["args"] || []
        {:stdio, command: command, args: args}

      true ->
        Logger.warning("[MCP Client] No transport config found: #{inspect(config)}")
        {:stdio, command: "echo", args: ["no-op"]}
    end
  end

  defp sync_tools(endpoint_id, state) do
    case Jido.MCP.list_tools(endpoint_id) do
      {:ok, %{tools: tools}} when is_list(tools) ->
        Logger.info("[MCP Client] Discovered #{length(tools)} tools from #{endpoint_id}")

        case build_proxy_modules(endpoint_id, tools) do
          {:ok, modules} ->
            Logger.info("[MCP Client] Registered #{length(modules)} proxy tools from #{endpoint_id}")
            %{state | tools: Map.put(state.tools, endpoint_id, modules)}

          {:error, reason} ->
            Logger.warning("[MCP Client] Failed to build proxies for #{endpoint_id}: #{inspect(reason)}")
            state
        end

      {:ok, _other} ->
        Logger.info("[MCP Client] No tools found at #{endpoint_id}")
        state

      {:error, reason} ->
        Logger.warning("[MCP Client] Failed to list tools from #{endpoint_id}: #{inspect(reason)}")
        state
    end
  rescue
    e ->
      Logger.warning("[MCP Client] Error syncing tools from #{endpoint_id}: #{Exception.message(e)}")
      state
  end

  defp build_proxy_modules(endpoint_id, tools) do
    {:ok, modules, _warnings, _skipped} =
      Jido.MCP.JidoAI.ProxyGenerator.build_modules(endpoint_id, tools, prefix: "mcp_#{endpoint_id}")

    {:ok, modules}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
