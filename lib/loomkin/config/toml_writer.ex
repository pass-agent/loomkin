defmodule Loomkin.Config.TomlWriter do
  @moduledoc """
  Simple TOML serializer for Loomkin configuration.

  Handles the limited subset of types used in `.loomkin.toml`:
  strings, numbers, booleans, lists of strings, and nested tables (max 3 levels).
  """

  @doc "Encode a map into a TOML string."
  @spec encode(map()) :: String.t()
  def encode(map) when is_map(map) do
    {top_level, tables} = split_top_level(map)

    top_lines = Enum.map_join(top_level, "\n", fn {k, v} -> "#{k} = #{encode_value(v)}" end)

    table_lines =
      tables
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("\n\n", fn {key, value} -> encode_table(key, value) end)

    [top_lines, table_lines]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp split_top_level(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.split_with(fn {_k, v} -> not is_map(v) end)
  end

  defp encode_table(prefix, map) when is_map(map) do
    {scalars, nested} = split_top_level(map)

    header = "[#{prefix}]"

    scalar_lines =
      scalars
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k} = #{encode_value(v)}" end)

    section = if scalar_lines == "", do: header, else: "#{header}\n#{scalar_lines}"

    nested_sections =
      nested
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("\n\n", fn {k, v} ->
        encode_table("#{prefix}.#{k}", v)
      end)

    if nested_sections == "" do
      section
    else
      "#{section}\n\n#{nested_sections}"
    end
  end

  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_value(v) when is_float(v), do: Float.to_string(v)
  defp encode_value(v) when is_atom(v), do: encode_value(Atom.to_string(v))

  defp encode_value(v) when is_binary(v) do
    escaped = v |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp encode_value(list) when is_list(list) do
    items = Enum.map_join(list, ", ", &encode_value/1)
    "[#{items}]"
  end
end
