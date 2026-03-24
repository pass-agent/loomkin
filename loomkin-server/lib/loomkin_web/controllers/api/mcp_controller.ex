defmodule LoomkinWeb.Api.McpController do
  use LoomkinWeb, :controller

  alias Loomkin.MCP.Client
  alias Loomkin.MCP.Server

  @doc "GET /api/v1/mcp"
  def index(conn, _params) do
    clients = serialize_clients()
    server = serialize_server()

    json(conn, %{
      server: server,
      clients: clients
    })
  end

  @doc "POST /api/v1/mcp/refresh"
  def refresh(conn, %{"name" => name}) do
    endpoint_id = {:mcp, name}
    Client.refresh(endpoint_id)
    json(conn, %{message: "refresh requested", endpoint: name})
  end

  def refresh(conn, _params) do
    Client.refresh()
    json(conn, %{message: "refresh requested for all endpoints"})
  end

  defp serialize_clients do
    statuses = Client.status()

    Enum.map(statuses, fn {{:mcp, name}, info} ->
      %{
        name: to_string(name),
        transport: serialize_transport(info.config),
        status: serialize_endpoint_status(info.status),
        tool_count: info.tool_count
      }
    end)
  rescue
    _ -> []
  end

  defp serialize_server do
    %{
      enabled: Server.enabled?(),
      tools:
        Server.tools()
        |> Enum.map(fn mod ->
          name =
            mod
            |> Module.split()
            |> List.last()
            |> Macro.underscore()

          %{name: name, module: inspect(mod)}
        end)
    }
  rescue
    _ -> %{enabled: false, tools: []}
  end

  defp serialize_transport(config) do
    cond do
      config[:url] || config["url"] ->
        %{type: "http", url: config[:url] || config["url"]}

      config[:command] || config["command"] ->
        command = config[:command] || config["command"]
        args = config[:args] || config["args"] || []
        %{type: "stdio", command: "#{command} #{Enum.join(args, " ")}"}

      true ->
        %{type: "unknown"}
    end
  end

  defp serialize_endpoint_status(:connected), do: "connected"
  defp serialize_endpoint_status({:error, reason}), do: "error: #{inspect(reason)}"
  defp serialize_endpoint_status(other), do: inspect(other)
end
