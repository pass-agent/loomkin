defmodule Loomkin.ProjectRules do
  @moduledoc "Loads and parses LOOMKIN.md project rules files."

  @type rules :: %{
          raw: String.t(),
          instructions: String.t(),
          rules: [String.t()],
          allowed_ops: %{String.t() => [String.t()]},
          denied_ops: [String.t()]
        }

  @candidates ["LOOMKIN.md", ".loomkin.md", "loomkin.md"]

  @recognized_sections ["Rules", "Allowed Operations", "Denied Operations"]

  @doc "Load and parse LOOMKIN.md from a project directory."
  @spec load(String.t()) :: {:ok, rules()} | {:error, term()}
  def load(project_path) do
    case find_rules_file(project_path) do
      nil ->
        {:ok, %{raw: "", instructions: "", rules: [], allowed_ops: %{}, denied_ops: []}}

      path ->
        parse_file(path)
    end
  end

  @doc "Format rules for system prompt injection."
  @spec format_for_prompt(rules()) :: String.t()
  def format_for_prompt(rules) do
    parts = []

    parts =
      if rules.instructions != "" do
        parts ++ ["## Project Instructions\n#{rules.instructions}"]
      else
        parts
      end

    parts =
      if rules.rules != [] do
        items = Enum.map_join(rules.rules, "\n", &"- #{&1}")
        parts ++ ["## Rules\n#{items}"]
      else
        parts
      end

    parts =
      if rules.allowed_ops != %{} do
        items =
          Enum.map_join(rules.allowed_ops, "\n", fn {category, patterns} ->
            "- #{category}: #{Enum.join(patterns, ", ")}"
          end)

        parts ++ ["## Allowed Operations\n#{items}"]
      else
        parts
      end

    parts =
      if rules.denied_ops != [] do
        items = Enum.map_join(rules.denied_ops, "\n", &"- #{&1}")
        parts ++ ["## Denied Operations\n#{items}"]
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  @doc "Find the rules file in a project directory."
  @spec find_rules_file(String.t()) :: String.t() | nil
  def find_rules_file(project_path) do
    Enum.find_value(@candidates, fn name ->
      path = Path.join(project_path, name)
      if File.exists?(path), do: path
    end)
  end

  defp parse_file(path) do
    content = File.read!(path)
    sections = split_sections(content)

    instructions =
      sections
      |> Enum.reject(fn {heading, _body} -> heading in @recognized_sections end)
      |> Enum.map(fn
        {nil, body} -> String.trim(body)
        {heading, body} -> "## #{heading}\n#{String.trim(body)}"
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    rules = extract_list_items(sections, "Rules")
    allowed_ops = extract_allowed_ops(sections)
    denied_ops = extract_list_items(sections, "Denied Operations")

    {:ok,
     %{
       raw: content,
       instructions: instructions,
       rules: rules,
       allowed_ops: allowed_ops,
       denied_ops: denied_ops
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp split_sections(content) do
    # Split on "## " headings at the start of a line
    parts = Regex.split(~r/^## /m, content)

    case parts do
      [preamble | rest] ->
        preamble_section = [{nil, preamble}]

        headed =
          Enum.map(rest, fn part ->
            case String.split(part, "\n", parts: 2) do
              [heading, body] -> {String.trim(heading), body}
              [heading] -> {String.trim(heading), ""}
            end
          end)

        preamble_section ++ headed

      [] ->
        [{nil, ""}]
    end
  end

  defp extract_list_items(sections, section_name) do
    sections
    |> Enum.filter(fn {heading, _} -> heading == section_name end)
    |> Enum.flat_map(fn {_, body} -> parse_list_items(body) end)
  end

  defp parse_list_items(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/^\s*[-*]\s+/, &1))
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^\s*[-*]\s+/, "")
      |> String.trim()
    end)
  end

  defp extract_allowed_ops(sections) do
    items =
      sections
      |> Enum.filter(fn {heading, _} -> heading == "Allowed Operations" end)
      |> Enum.flat_map(fn {_, body} -> parse_list_items(body) end)

    Enum.reduce(items, %{}, fn item, acc ->
      case String.split(item, ":", parts: 2) do
        [category, patterns_str] ->
          key =
            category
            |> String.trim()
            |> String.downcase()

          patterns =
            patterns_str
            |> String.split(",")
            |> Enum.map(fn p ->
              p |> String.trim() |> String.trim("`")
            end)
            |> Enum.reject(&(&1 == ""))

          Map.put(acc, key, patterns)

        _ ->
          acc
      end
    end)
  end
end
