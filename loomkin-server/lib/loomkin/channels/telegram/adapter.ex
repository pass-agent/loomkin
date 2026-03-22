defmodule Loomkin.Channels.Telegram.Adapter do
  @moduledoc """
  Telegram adapter implementing the `Loomkin.Channels.Adapter` behaviour.

  Uses the Telegex library to send messages, inline keyboards, and
  activity notifications to Telegram chats.
  """

  @behaviour Loomkin.Channels.Adapter

  alias Loomkin.Channels.Telegram.Formatter

  # --- Adapter Callbacks ---

  @impl true
  def send_text(binding, text, _opts \\ []) do
    chat_id = binding.channel_id

    Formatter.split_message(text)
    |> Enum.reduce(:ok, fn chunk, acc ->
      case acc do
        :ok ->
          case telegex().send_message(chat_id, chunk, parse_mode: "MarkdownV2") do
            {:ok, _msg} -> :ok
            {:error, reason} -> {:error, reason}
          end

        error ->
          error
      end
    end)
  end

  @impl true
  def send_question(binding, question_id, question, options) do
    chat_id = binding.channel_id

    keyboard = %{
      inline_keyboard:
        options
        |> Enum.with_index()
        |> Enum.map(fn {option, idx} ->
          [%{text: option, callback_data: "ask_user:#{question_id}:#{idx}"}]
        end)
    }

    escaped_question = Formatter.escape(question)

    case telegex().send_message(chat_id, escaped_question,
           parse_mode: "MarkdownV2",
           reply_markup: keyboard
         ) do
      {:ok, _msg} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def send_activity(binding, event) do
    chat_id = binding.channel_id
    text = Formatter.format_activity(event)

    case telegex().send_message(chat_id, text, parse_mode: "MarkdownV2") do
      {:ok, _msg} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def format_agent_message(agent_name, content) do
    Formatter.format_agent_message(agent_name, content)
  end

  @impl true
  def parse_inbound(raw_event) when is_map(raw_event) do
    cond do
      # Callback query from inline keyboard button press
      callback_query = Map.get(raw_event, "callback_query") ->
        telegram_callback_id = Map.get(callback_query, "id", "")
        data = Map.get(callback_query, "data", "")

        # Answer the callback query to remove the loading indicator
        Task.Supervisor.start_child(Loomkin.Channels.WebhookTaskSupervisor, fn ->
          case telegex().answer_callback_query(telegram_callback_id) do
            {:ok, _} ->
              :ok

            {:error, _reason} ->
              :ok
          end
        end)

        # Include user info for ACL checks on callbacks
        from = get_in(callback_query, ["from"]) || %{}
        from_id = Map.get(from, "id")

        # Extract question_id from structured callback_data "ask_user:question_id:index"
        case String.split(data, ":", parts: 3) do
          ["ask_user", question_id, _index] ->
            {:callback, question_id, %{raw: data, from_id: from_id}}

          _ ->
            # Legacy fallback: treat data as-is
            {:callback, data, %{raw: data, from_id: from_id}}
        end

      # Regular text message
      message = Map.get(raw_event, "message") ->
        text = Map.get(message, "text", "")
        from = Map.get(message, "from", %{})

        metadata = %{
          message_id: Map.get(message, "message_id"),
          chat_id: get_in(message, ["chat", "id"]),
          from_id: Map.get(from, "id"),
          from_username: Map.get(from, "username"),
          from_first_name: Map.get(from, "first_name")
        }

        {:message, text, metadata}

      # Edited message — treat like a regular message
      message = Map.get(raw_event, "edited_message") ->
        text = Map.get(message, "text", "")
        from = Map.get(message, "from", %{})

        metadata = %{
          message_id: Map.get(message, "message_id"),
          chat_id: get_in(message, ["chat", "id"]),
          from_id: Map.get(from, "id"),
          from_username: Map.get(from, "username"),
          edited: true
        }

        {:message, text, metadata}

      # Anything else (channel posts, media, etc.)
      true ->
        :ignore
    end
  end

  def parse_inbound(_), do: :ignore

  defp telegex, do: Application.get_env(:loomkin, :telegex_module, Telegex)
end
