defmodule Loomkin.Channels.Telegram.Poller do
  @moduledoc """
  Long-polling GenServer for receiving Telegram updates without a webhook.

  Useful for local development where setting up ngrok or a public URL
  is impractical. Uses `Telegex.get_updates` in a loop with a 30-second
  long-poll timeout.

  Enable by setting `mode = "polling"` in the `[channels.telegram]`
  section of `.loomkin.toml`.

  Each received update is dispatched through `Channels.Router.handle_inbound/4`
  exactly as the webhook handler does, ensuring identical behaviour.
  """

  use GenServer

  alias Loomkin.Channels.Router, as: ChannelRouter

  @poll_timeout 30
  @retry_delay_ms 3_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    send(self(), :poll)
    {:ok, %{offset: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    case telegex().get_updates(offset: state.offset, timeout: @poll_timeout) do
      {:ok, updates} when is_list(updates) ->
        new_offset = process_updates(updates, state.offset)
        send(self(), :poll)
        {:noreply, %{state | offset: new_offset}}

      {:ok, _} ->
        # Unexpected response shape — retry after delay
        Process.send_after(self(), :poll, @retry_delay_ms)
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :poll, @retry_delay_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp process_updates([], offset), do: offset

  defp process_updates(updates, _offset) do
    Enum.each(updates, fn update ->
      channel_id = extract_chat_id(update)

      if channel_id do
        channel_id_str = to_string(channel_id)

        case ChannelRouter.handle_inbound(
               Loomkin.Channels.Telegram.Adapter,
               :telegram,
               channel_id_str,
               update
             ) do
          {:ok, response} when is_binary(response) ->
            telegex().send_message(channel_id_str, response, [])

          {:ok, _} ->
            :ok

          {:error, :no_binding} ->
            :ok

          {:error, _reason} ->
            :ok
        end
      else
        :ok
      end
    end)

    # Return the next offset: last update_id + 1
    last_update = List.last(updates)
    update_id = Map.get(last_update, "update_id") || Map.get(last_update, :update_id, 0)
    update_id + 1
  end

  defp extract_chat_id(update) do
    cond do
      chat_id = get_in(update, ["message", "chat", "id"]) -> chat_id
      chat_id = get_in(update, ["edited_message", "chat", "id"]) -> chat_id
      chat_id = get_in(update, ["callback_query", "message", "chat", "id"]) -> chat_id
      true -> nil
    end
  end

  defp telegex, do: Application.get_env(:loomkin, :telegex_module, Telegex)
end
