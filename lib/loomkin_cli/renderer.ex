defmodule LoomkinCli.Renderer do
  @moduledoc """
  Terminal rendering utilities for the Loomkin CLI.

  Handles markdown formatting, diffs, tool call display,
  error messages, and the welcome banner.
  """

  @doc """
  Render markdown text with basic ANSI terminal formatting.
  """
  def render_markdown(text) do
    text
    |> String.split("\n")
    |> Enum.map(&format_markdown_line/1)
    |> Enum.join("\n")
    |> IO.puts()
  end

  @doc """
  Render a unified diff with colored output.
  """
  def render_diff(diff_text) do
    diff_text
    |> String.split("\n")
    |> Enum.map(fn
      "+" <> _ = line -> IO.ANSI.green() <> line <> IO.ANSI.reset()
      "-" <> _ = line -> IO.ANSI.red() <> line <> IO.ANSI.reset()
      "@@" <> _ = line -> IO.ANSI.cyan() <> line <> IO.ANSI.reset()
      line -> line
    end)
    |> Enum.join("\n")
    |> IO.puts()
  end

  @doc """
  Render a tool call notification.
  """
  def render_tool_call(tool_name, params) do
    summary = params_summary(params)

    IO.puts(
      IO.ANSI.faint() <>
        "  [#{tool_name}] " <>
        summary <>
        IO.ANSI.reset()
    )
  end

  @doc """
  Render an error message in red.
  """
  def render_error(message) do
    IO.puts(IO.ANSI.red() <> "  Error: " <> message <> IO.ANSI.reset())
  end

  @doc """
  Print the Loomkin welcome banner.
  """
  def render_welcome(opts \\ %{}) do
    model = Loomkin.Config.get(:model, :default) || "not configured"
    project = Map.get(opts, :project_path, File.cwd!())

    IO.puts("""

    #{IO.ANSI.bright()}#{IO.ANSI.cyan()}Loom#{IO.ANSI.reset()} v#{Loomkin.version()}
    #{IO.ANSI.faint()}An Elixir-native AI coding assistant#{IO.ANSI.reset()}

    #{IO.ANSI.faint()}Model:   #{IO.ANSI.reset()}#{model}
    #{IO.ANSI.faint()}Project: #{IO.ANSI.reset()}#{project}
    #{IO.ANSI.faint()}Type /help for commands#{IO.ANSI.reset()}
    """)
  end

  # --- Private formatting helpers ---

  defp format_markdown_line("# " <> heading) do
    IO.ANSI.bright() <> IO.ANSI.underline() <> heading <> IO.ANSI.reset()
  end

  defp format_markdown_line("## " <> heading) do
    IO.ANSI.bright() <> heading <> IO.ANSI.reset()
  end

  defp format_markdown_line("### " <> heading) do
    IO.ANSI.bright() <> heading <> IO.ANSI.reset()
  end

  defp format_markdown_line("```" <> _ = line) do
    IO.ANSI.faint() <> IO.ANSI.cyan() <> line <> IO.ANSI.reset()
  end

  defp format_markdown_line("- " <> item) do
    "  * " <> item
  end

  defp format_markdown_line("* " <> item) do
    "  * " <> item
  end

  defp format_markdown_line(line) do
    line
    |> format_inline_bold()
    |> format_inline_code()
  end

  defp format_inline_bold(text) do
    Regex.replace(~r/\*\*(.+?)\*\*/, text, fn _, content ->
      IO.ANSI.bright() <> content <> IO.ANSI.reset()
    end)
  end

  defp format_inline_code(text) do
    Regex.replace(~r/`(.+?)`/, text, fn _, content ->
      IO.ANSI.faint() <> IO.ANSI.cyan() <> content <> IO.ANSI.reset()
    end)
  end

  defp params_summary(params) when is_map(params) do
    params
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} ->
      "#{k}=#{inspect(v, limit: 30, printable_limit: 50)}"
    end)
  end

  defp params_summary(params), do: inspect(params, limit: 50)
end
