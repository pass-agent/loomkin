defmodule Loomkin.Vault.Sources.Url do
  @moduledoc "Fetches content from web URLs using Req."

  @behaviour Loomkin.Vault.Sources.Source

  @impl true
  def fetch(url, opts \\ []) do
    if valid_url?(url) do
      do_fetch(url, opts)
    else
      {:error, "Invalid URL: #{url}"}
    end
  end

  defp do_fetch(url, _opts) do
    case Req.get(url, receive_timeout: 30_000, max_redirects: 5) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        content_type = extract_content_type(headers)
        {content, title} = process_body(body, content_type, url)

        {:ok,
         %{
           content: content,
           title: title,
           content_type: content_type,
           byte_size: byte_size(content)
         }}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Not found (404): #{url}"}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "Unauthorized (401): #{url}"}

      {:ok, %Req.Response{status: 403}} ->
        {:error, "Forbidden (403): #{url}"}

      {:ok, %Req.Response{status: status}} when status >= 400 ->
        {:error, "HTTP #{status} error fetching #{url}"}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "Request timed out for #{url}"}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, "Connection refused for #{url}"}

      {:error, reason} ->
        {:error, "Failed to fetch #{url}: #{inspect(reason)}"}
    end
  end

  defp extract_content_type(headers) do
    headers
    |> Enum.find_value(fn
      {"content-type", [value | _]} -> value
      {"content-type", value} when is_binary(value) -> value
      _ -> nil
    end)
    |> case do
      nil -> "text/plain"
      ct -> ct |> String.split(";") |> hd() |> String.trim()
    end
  end

  defp process_body(body, content_type, url) when is_binary(body) do
    if String.contains?(content_type, "html") do
      title = extract_html_title(body) || title_from_url(url)
      text = strip_html(body)
      {text, title}
    else
      {body, title_from_url(url)}
    end
  end

  defp process_body(body, _content_type, url) do
    text = inspect(body)
    {text, title_from_url(url)}
  end

  defp extract_html_title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html) do
      [_, title] -> title |> String.trim() |> unescape_html()
      _ -> nil
    end
  end

  defp strip_html(html) do
    html
    # Remove script and style blocks entirely
    |> String.replace(~r/<(script|style)[^>]*>.*?<\/\1>/is, "")
    # Remove HTML comments
    |> String.replace(~r/<!--.*?-->/s, "")
    # Replace block-level tags with newlines
    |> String.replace(~r/<\/(p|div|h[1-6]|li|tr|blockquote|pre|br\s*\/?)>/i, "\n")
    |> String.replace(~r/<br\s*\/?\s*>/i, "\n")
    # Remove remaining tags
    |> String.replace(~r/<[^>]+>/, "")
    # Unescape common HTML entities
    |> unescape_html()
    # Collapse multiple blank lines
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp unescape_html(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
  end

  defp title_from_url(url) do
    uri = URI.parse(url)

    cond do
      uri.path not in [nil, "", "/"] ->
        uri.path |> Path.basename() |> URI.decode()

      uri.host ->
        uri.host

      true ->
        nil
    end
  end

  defp valid_url?(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and not is_nil(uri.host)
  end
end
