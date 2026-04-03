defmodule Loomkin.Tools.FetchContent do
  @moduledoc """
  Agent tool for fetching content from external sources.

  Dispatches to the appropriate source adapter based on the `source` param.
  Supports web URLs and Google Drive. Has zero vault dependency.
  """

  use Jido.Action,
    name: "fetch_content",
    description: """
    Fetch content from an external source. Supports web URLs and Google Drive.
    Returns the content as text. Use this to retrieve meeting transcripts,
    reference documents, or any content stored outside the vault.
    """,
    schema: [
      source: [
        type: :string,
        required: true,
        doc: """
        Content source type:
        - url: Fetch from a web URL (returns text or converts HTML to markdown)
        - google_drive: Fetch from Google Drive (requires Google OAuth)
        """
      ],
      identifier: [
        type: :string,
        required: true,
        doc: """
        Source-specific identifier:
        - url: The full URL (e.g. https://example.com/page)
        - google_drive: File ID (from the Drive URL) or search query (e.g. "title:meeting notes")
        """
      ],
      format: [
        type: :string,
        doc: "Preferred output format: text, markdown. Default: text."
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  @adapters %{
    "url" => Loomkin.Vault.Sources.Url,
    "google_drive" => Loomkin.Vault.Sources.GoogleDrive
  }

  @impl true
  def run(params, _context) do
    source = param!(params, :source)
    identifier = param!(params, :identifier)
    format = param(params, :format) || "text"

    case Map.fetch(@adapters, source) do
      {:ok, adapter} ->
        case adapter.fetch(identifier, format: format) do
          {:ok, result} ->
            {:ok,
             %{
               result:
                 """
                 Fetched content from #{source}:
                   Title: #{result.title || "untitled"}
                   Type: #{result.content_type || "unknown"}
                   Size: #{result.byte_size} bytes

                 #{result.content}
                 """
                 |> String.trim()
             }}

          {:error, reason} ->
            {:error, "Failed to fetch from #{source}: #{reason}"}
        end

      :error ->
        supported = @adapters |> Map.keys() |> Enum.join(", ")
        {:error, "Unknown source '#{source}'. Supported: #{supported}"}
    end
  end
end
