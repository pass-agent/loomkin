defmodule Loomkin.Tools.LspDiagnostics do
  @moduledoc "Retrieves LSP diagnostics for a file from connected language servers."

  use Jido.Action,
    name: "lsp_diagnostics",
    description:
      "Get compiler diagnostics (errors, warnings) for a file from the language server. " <>
        "Use severity filter to show only errors or warnings.",
    schema: [
      file_path: [type: :string, required: true, doc: "Path to the file (relative to project root)"],
      severity: [
        type: :string,
        doc: "Filter by severity: error, warning, information, hint. Omit for all."
      ],
      server: [
        type: :string,
        doc: "LSP server name to query. Omit to query all connected servers."
      ]
    ]

  import Loomkin.Tool, only: [safe_path!: 2, param!: 2, param: 2]

  alias Loomkin.LSP.Supervisor, as: LSPSupervisor
  alias Loomkin.LSP.Client

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    file_path = param!(params, :file_path)
    severity_filter = param(params, :severity)
    server_name = param(params, :server)

    full_path = safe_path!(file_path, project_path)

    if not File.exists?(full_path) do
      {:error, "File not found: #{full_path}"}
    else
      servers =
        if server_name do
          [server_name]
        else
          LSPSupervisor.list_clients()
        end

      if servers == [] do
        {:ok, %{result: "No LSP servers connected. Configure LSP servers in .loomkin.toml under [lsp]."}}
      else
        diagnostics = collect_diagnostics(servers, full_path, severity_filter)
        {:ok, %{result: format_diagnostics(file_path, diagnostics)}}
      end
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp collect_diagnostics(servers, file_path, severity_filter) do
    servers
    |> Enum.flat_map(fn name ->
      case Client.status(name) do
        :ready ->
          case Client.get_diagnostics(name, file_path) do
            {:ok, diags} ->
              Enum.map(diags, &Map.put(&1, :server, name))

            _ ->
              []
          end

        _ ->
          []
      end
    end)
    |> filter_severity(severity_filter)
    |> Enum.sort_by(& &1.line)
  end

  defp filter_severity(diags, nil), do: diags

  defp filter_severity(diags, severity) when is_binary(severity) do
    target = String.to_existing_atom(severity)
    Enum.filter(diags, fn d -> d.severity == target end)
  rescue
    ArgumentError -> diags
  end

  defp format_diagnostics(file_path, []) do
    "No diagnostics for #{file_path}."
  end

  defp format_diagnostics(file_path, diagnostics) do
    header = "Diagnostics for #{file_path} (#{length(diagnostics)} issues):\n\n"

    lines =
      Enum.map(diagnostics, fn d ->
        source = if d.source != "", do: " [#{d.source}]", else: ""
        server = if d[:server], do: " (#{d.server})", else: ""
        code = if d[:code], do: " #{d.code}", else: ""

        "  Line #{d.line}: #{d.severity}#{source}#{code}#{server}\n    #{d.message}"
      end)

    header <> Enum.join(lines, "\n\n")
  end
end
