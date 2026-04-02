defmodule Loomkin.Vault.Parser do
  @moduledoc "Parses and serializes vault entries (YAML frontmatter + markdown body)."

  alias Loomkin.Vault.Entry

  @frontmatter_delimiter "---"

  @doc "Parse a markdown string with YAML frontmatter into an Entry struct."
  @spec parse(String.t()) :: {:ok, Entry.t()} | {:error, String.t()}
  def parse(content) when is_binary(content) do
    case split_frontmatter(content) do
      {:ok, yaml_string, body} ->
        parse_with_frontmatter(yaml_string, body)

      :none ->
        {:ok, %Entry{body: String.trim(content), metadata: %{}, tags: []}}
    end
  end

  @doc "Parse, raising on failure."
  @spec parse!(String.t()) :: Entry.t()
  def parse!(content) do
    case parse(content) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "failed to parse vault entry: #{reason}"
    end
  end

  @doc "Serialize an Entry struct back to markdown with YAML frontmatter."
  @spec serialize(Entry.t()) :: String.t()
  def serialize(%Entry{} = entry) do
    frontmatter_map = build_frontmatter_map(entry)

    if map_size(frontmatter_map) == 0 do
      entry.body || ""
    else
      yaml = encode_yaml(frontmatter_map)
      body = entry.body || ""

      "#{@frontmatter_delimiter}\n#{yaml}#{@frontmatter_delimiter}\n#{body}"
    end
  end

  # --- Private helpers ---

  defp split_frontmatter(content) do
    trimmed = String.trim_leading(content)

    if String.starts_with?(trimmed, @frontmatter_delimiter <> "\n") do
      # Strip the opening delimiter + newline
      rest = String.slice(trimmed, (String.length(@frontmatter_delimiter) + 1)..-1//1)

      cond do
        # Empty frontmatter with body: ---\n---\nBody
        String.starts_with?(rest, @frontmatter_delimiter <> "\n") ->
          body = String.slice(rest, (String.length(@frontmatter_delimiter) + 1)..-1//1)
          {:ok, "", String.trim(body)}

        # Empty frontmatter with no body: ---\n---
        rest == @frontmatter_delimiter or rest == @frontmatter_delimiter <> "\n" ->
          {:ok, "", ""}

        true ->
          case String.split(rest, "\n" <> @frontmatter_delimiter <> "\n", parts: 2) do
            [yaml_string, body] ->
              {:ok, yaml_string, String.trim(body)}

            [yaml_only] ->
              if String.ends_with?(yaml_only, "\n" <> @frontmatter_delimiter) do
                yaml =
                  yaml_only
                  |> String.trim_trailing()
                  |> String.trim_trailing(@frontmatter_delimiter)
                  |> String.trim_trailing()

                {:ok, yaml, ""}
              else
                :none
              end
          end
      end
    else
      :none
    end
  end

  defp parse_with_frontmatter(yaml_string, body) do
    yaml_string = String.trim(yaml_string)

    if yaml_string == "" do
      {:ok, %Entry{body: body, metadata: %{}, tags: []}}
    else
      case YamlElixir.read_from_string(yaml_string) do
        {:ok, metadata} when is_map(metadata) ->
          entry = %Entry{
            title: Map.get(metadata, "title"),
            entry_type: Map.get(metadata, "type"),
            tags: Map.get(metadata, "tags", []) |> normalize_tags(),
            body: body,
            metadata: stringify_keys(metadata)
          }

          {:ok, entry}

        {:ok, _} ->
          {:error, "frontmatter must be a YAML mapping"}

        {:error, %YamlElixir.ParsingError{} = error} ->
          {:error, "invalid YAML frontmatter: #{Exception.message(error)}"}
      end
    end
  end

  defp normalize_tags(tags) when is_list(tags), do: Enum.map(tags, &to_string/1)
  defp normalize_tags(_), do: []

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp build_frontmatter_map(entry) do
    base = entry.metadata || %{}

    base
    |> maybe_put("title", entry.title)
    |> maybe_put("type", entry.entry_type)
    |> maybe_put_tags(entry.tags)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tags(map, []), do: Map.delete(map, "tags")
  defp maybe_put_tags(map, nil), do: Map.delete(map, "tags")
  defp maybe_put_tags(map, tags), do: Map.put(map, "tags", tags)

  defp encode_yaml(map) when map_size(map) == 0, do: ""

  defp encode_yaml(map) do
    # Put title, type, tags first for readability, then remaining keys alphabetically
    priority_keys = ["title", "type", "tags"]
    remaining_keys = map |> Map.keys() |> Enum.reject(&(&1 in priority_keys)) |> Enum.sort()
    ordered_keys = Enum.filter(priority_keys, &Map.has_key?(map, &1)) ++ remaining_keys

    ordered_keys
    |> Enum.map(fn key -> encode_yaml_pair(key, Map.fetch!(map, key)) end)
    |> Enum.join("")
  end

  defp encode_yaml_pair(key, value) when is_list(value) do
    items = Enum.map_join(value, "", fn item -> "  - #{encode_yaml_value(item)}\n" end)
    "#{key}:\n#{items}"
  end

  defp encode_yaml_pair(key, value) do
    "#{key}: #{encode_yaml_value(value)}\n"
  end

  defp encode_yaml_value(value) when is_binary(value) do
    if String.contains?(value, [": ", "#", "'", "\"", "\n", "[", "]", "{", "}"]) do
      "\"#{String.replace(value, "\"", "\\\"")}\""
    else
      value
    end
  end

  defp encode_yaml_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_yaml_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_yaml_value(true), do: "true"
  defp encode_yaml_value(false), do: "false"
  defp encode_yaml_value(nil), do: "null"
  defp encode_yaml_value(value), do: inspect(value)
end
