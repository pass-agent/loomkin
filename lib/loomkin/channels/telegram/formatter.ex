defmodule Loomkin.Channels.Telegram.Formatter do
  @moduledoc """
  Converts standard markdown and agent messages into Telegram MarkdownV2 format.

  Telegram MarkdownV2 requires escaping special characters outside of formatting
  entities. See: https://core.telegram.org/bots/api#markdownv2-style
  """

  # Characters that must be escaped in MarkdownV2 outside of entities
  @special_chars [
    "_",
    "*",
    "[",
    "]",
    "(",
    ")",
    "~",
    "`",
    ">",
    "#",
    "+",
    "-",
    "=",
    "|",
    "{",
    "}",
    ".",
    "!"
  ]

  @telegram_max_length 4096

  @doc """
  Format an agent message with the agent name as a bold header.
  """
  @spec format_agent_message(String.t(), String.t()) :: String.t()
  def format_agent_message(agent_name, content) do
    escaped_name = escape(agent_name)
    escaped_content = escape(content)
    "*#{escaped_name}*\n#{escaped_content}"
  end

  @doc """
  Escape a string for Telegram MarkdownV2.

  All special characters outside of formatting entities must be preceded
  with a backslash.
  """
  @spec escape(String.t()) :: String.t()
  def escape(text) when is_binary(text) do
    Enum.reduce(@special_chars, text, fn char, acc ->
      String.replace(acc, char, "\\#{char}")
    end)
  end

  @doc """
  Split a message into chunks that fit within Telegram's 4096 character limit.

  Attempts to split at newline boundaries when possible.
  """
  @spec split_message(String.t()) :: [String.t()]
  def split_message(text) when byte_size(text) <= @telegram_max_length, do: [text]

  def split_message(text) do
    do_split(text, [])
  end

  defp do_split("", acc), do: Enum.reverse(acc)

  defp do_split(text, acc) when byte_size(text) <= @telegram_max_length do
    Enum.reverse([text | acc])
  end

  defp do_split(text, acc) do
    chunk = String.slice(text, 0, @telegram_max_length)

    # Try to split at the last newline within the chunk
    case String.split(chunk, "\n") |> List.delete_at(-1) do
      [] ->
        # No newline found, split at the hard limit
        rest = String.slice(text, @telegram_max_length, String.length(text))
        do_split(rest, [chunk | acc])

      parts ->
        good_chunk = Enum.join(parts, "\n") <> "\n"
        rest = String.slice(text, String.length(good_chunk), String.length(text))
        do_split(rest, [String.trim_trailing(good_chunk) | acc])
    end
  end

  @doc """
  Format an activity event for display in Telegram.
  """
  @spec format_activity(map()) :: String.t()
  def format_activity(event) do
    type = Map.get(event, :type, :unknown)

    case type do
      :conflict_detected ->
        agents = Map.get(event, :agents, []) |> Enum.join(", ")
        "⚠️ *Conflict detected* between #{escape(agents)}"

      :consensus_reached ->
        topic = Map.get(event, :topic, "unknown")
        "✅ *Consensus reached* on #{escape(to_string(topic))}"

      :task_completed ->
        agent = Map.get(event, :agent_name, "unknown")
        task = Map.get(event, :task, "unknown")
        "✅ *#{escape(agent)}* completed: #{escape(to_string(task))}"

      _ ->
        "📋 Activity: #{escape(inspect(type))}"
    end
  end
end
