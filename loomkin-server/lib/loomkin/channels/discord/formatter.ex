defmodule Loomkin.Channels.Discord.Formatter do
  @moduledoc """
  Formatting utilities for Discord messages.

  Converts standard markdown to Discord-compatible markdown and handles
  message splitting for Discord's 2000 character limit.
  """

  @max_message_length 2000

  @doc "Format an agent message for Discord display using an embed-style layout."
  @spec format_agent_message(String.t(), String.t()) :: String.t()
  def format_agent_message(agent_name, content) do
    "**#{agent_name}**\n#{content}"
  end

  @doc """
  Split a message into chunks that fit within Discord's character limit.

  Tries to split on newlines, then spaces, falling back to hard splits.
  """
  @spec split_message(String.t()) :: [String.t()]
  def split_message(text) when byte_size(text) <= @max_message_length, do: [text]

  def split_message(text) do
    do_split(text, [])
  end

  @doc "Convert standard markdown to Discord-flavored markdown."
  @spec to_discord_markdown(String.t()) :: String.t()
  def to_discord_markdown(text) do
    # Discord supports most standard markdown, main differences:
    # - No HTML tags (strip them)
    # - Headers use # but need a newline after
    text
    |> String.replace(~r/<[^>]+>/, "")
  end

  @doc """
  Build an embed map for agent activity.

  Returns a map compatible with the Nostrum embed format.
  """
  @spec activity_embed(String.t(), String.t(), atom()) :: map()
  def activity_embed(title, description, role \\ :default) do
    %{
      title: title,
      description: description,
      color: role_color(role),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc """
  Build button components for ask_user options.

  Returns a list of action row component maps compatible with Nostrum.
  """
  @spec question_buttons(String.t(), [String.t()]) :: [map()]
  def question_buttons(question_id, options) do
    buttons =
      options
      |> Enum.with_index()
      |> Enum.map(fn {label, idx} ->
        %{
          type: 2,
          style: 1,
          label: truncate(label, 80),
          custom_id: "ask_user:#{question_id}:#{idx}"
        }
      end)

    # Discord allows max 5 buttons per action row
    buttons
    |> Enum.chunk_every(5)
    |> Enum.map(fn row_buttons ->
      %{type: 1, components: row_buttons}
    end)
  end

  # --- Private ---

  defp do_split("", acc), do: Enum.reverse(acc)

  defp do_split(text, acc) when byte_size(text) <= @max_message_length do
    Enum.reverse([text | acc])
  end

  defp do_split(text, acc) do
    chunk = String.slice(text, 0, @max_message_length)

    # Try to find a clean break point
    split_pos =
      case last_index(chunk, "\n") do
        nil ->
          case last_index(chunk, " ") do
            nil -> @max_message_length
            pos -> pos
          end

        pos ->
          pos
      end

    {part, rest} = String.split_at(text, split_pos)
    rest = String.trim_leading(rest, "\n")
    do_split(rest, [part | acc])
  end

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max - 3) <> "..."
    else
      text
    end
  end

  defp role_color(:lead), do: 0xFF6B35
  defp role_color(:researcher), do: 0x4ECDC4
  defp role_color(:coder), do: 0x45B7D1
  defp role_color(:reviewer), do: 0x96CEB4
  defp role_color(:tester), do: 0xFECE44
  defp role_color(_), do: 0x7C8DB5

  defp last_index(string, pattern) do
    case :binary.matches(string, pattern) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
