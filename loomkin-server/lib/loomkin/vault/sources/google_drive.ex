defmodule Loomkin.Vault.Sources.GoogleDrive do
  @moduledoc "Fetches content from Google Drive using the user's OAuth token."

  @behaviour Loomkin.Vault.Sources.Source

  @drive_api_base "https://www.googleapis.com/drive/v3"

  # Google Workspace MIME types that require export
  @google_docs_mime "application/vnd.google-apps.document"
  @google_sheets_mime "application/vnd.google-apps.spreadsheet"
  @google_slides_mime "application/vnd.google-apps.presentation"

  @impl true
  def fetch(identifier, opts \\ []) do
    case get_token() do
      nil ->
        {:error,
         "Google OAuth not configured. Connect Google in Settings > Auth to use Google Drive."}

      token ->
        do_fetch(identifier, token, opts)
    end
  end

  defp do_fetch(identifier, token, opts) do
    if file_id?(identifier) do
      fetch_by_id(identifier, token, opts)
    else
      search_and_fetch(identifier, token, opts)
    end
  end

  defp fetch_by_id(file_id, token, _opts) do
    with {:ok, metadata} <- get_file_metadata(file_id, token),
         {:ok, content} <- get_file_content(file_id, metadata["mimeType"], token) do
      {:ok,
       %{
         content: content,
         title: metadata["name"],
         content_type: metadata["mimeType"],
         byte_size: byte_size(content)
       }}
    end
  end

  defp search_and_fetch(query, token, opts) do
    # Strip "title:" prefix if present
    clean_query = String.replace(query, ~r/^title:\s*/i, "")

    search_url =
      "#{@drive_api_base}/files?" <>
        URI.encode_query(%{
          "q" => "name contains '#{escape_drive_query(clean_query)}'",
          "fields" => "files(id,name,mimeType)",
          "pageSize" => "1"
        })

    case api_get(search_url, token) do
      {:ok, %{"files" => [first | _]}} ->
        fetch_by_id(first["id"], token, opts)

      {:ok, %{"files" => []}} ->
        {:error, "No files found matching '#{clean_query}' in Google Drive"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_file_metadata(file_id, token) do
    url =
      "#{@drive_api_base}/files/#{file_id}?" <>
        URI.encode_query(%{"fields" => "name,mimeType,modifiedTime"})

    api_get(url, token)
  end

  defp get_file_content(file_id, mime_type, token) do
    cond do
      mime_type == @google_docs_mime ->
        export_file(file_id, "text/plain", token)

      mime_type == @google_sheets_mime ->
        export_file(file_id, "text/csv", token)

      mime_type == @google_slides_mime ->
        export_file(file_id, "text/plain", token)

      true ->
        download_file(file_id, token)
    end
  end

  defp export_file(file_id, export_mime, token) do
    url =
      "#{@drive_api_base}/files/#{file_id}/export?" <>
        URI.encode_query(%{"mimeType" => export_mime})

    case Req.get(url,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, drive_error_message(status, file_id)}

      {:error, reason} ->
        {:error, "Failed to export file #{file_id}: #{inspect(reason)}"}
    end
  end

  defp download_file(file_id, token) do
    url =
      "#{@drive_api_base}/files/#{file_id}?" <>
        URI.encode_query(%{"alt" => "media"})

    case Req.get(url,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, drive_error_message(status, file_id)}

      {:error, reason} ->
        {:error, "Failed to download file #{file_id}: #{inspect(reason)}"}
    end
  end

  defp api_get(url, token) do
    case Req.get(url,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, drive_error_message(status, url)}

      {:error, reason} ->
        {:error, "Google Drive API error: #{inspect(reason)}"}
    end
  end

  defp drive_error_message(401, _target),
    do: "Google OAuth token expired. Re-authenticate in Settings > Auth."

  defp drive_error_message(403, _target),
    do: "Access denied. You don't have permission to access this file."

  defp drive_error_message(404, target),
    do: "File not found: #{target}"

  defp drive_error_message(status, _target),
    do: "Google Drive API returned HTTP #{status}"

  # A Google Drive file ID is typically 20-60 alphanumeric characters with hyphens/underscores
  defp file_id?(identifier) do
    Regex.match?(~r/\A[a-zA-Z0-9_-]{20,60}\z/, identifier)
  end

  defp escape_drive_query(query) do
    String.replace(query, "'", "\\'")
  end

  defp get_token do
    Loomkin.Auth.TokenStore.get_access_token(:google)
  end
end
