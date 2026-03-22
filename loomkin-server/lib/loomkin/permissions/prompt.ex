defmodule Loomkin.Permissions.Prompt do
  @moduledoc """
  Terminal-based permission prompts for tool execution.
  """

  @doc """
  Ask the user whether to allow a tool invocation.

  Displays the tool name and details, then prompts for a decision.
  Returns `:yes`, `:no`, or `:always`.
  """
  def ask(tool_name, details) do
    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        IO.ANSI.bright() <>
        "  [#{tool_name}]" <>
        IO.ANSI.reset() <>
        " wants to: " <>
        details
    )

    IO.puts("")

    response =
      IO.gets(
        IO.ANSI.cyan() <>
          "  [y]es / [n]o / [a]lways for this session: " <>
          IO.ANSI.reset()
      )

    case response |> to_string() |> String.trim() |> String.downcase() do
      input when input in ["y", "yes"] -> :yes
      input when input in ["a", "always"] -> :always
      _ -> :no
    end
  end
end
