defmodule Loomkin.Channels.Telegram.Webhook do
  @moduledoc """
  Plug-based webhook handler for Telegram bot updates.

  Receives POST requests from Telegram's webhook API, decodes the JSON
  payload, and dispatches to the Channel Router for processing.

  Mount this in your Phoenix router:

      scope "/api/webhooks" do
        post "/telegram", Loomkin.Channels.Telegram.Webhook, :handle
      end
  """

  import Plug.Conn

  alias Loomkin.Channels.Router, as: ChannelRouter

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    with :ok <- verify_secret_token(conn),
         {:ok, body, conn} <- read_body(conn),
         {:ok, update} <- Jason.decode(body) do
      handle_update(conn, update)
    else
      {:error, :unauthorized} ->
        send_resp(conn, 401, "Unauthorized")

      {:error, :invalid} ->
        send_resp(conn, 400, "Bad Request")

      {:error, %Jason.DecodeError{}} ->
        send_resp(conn, 400, "Invalid JSON")
    end
  end

  defp verify_secret_token(conn) do
    case channel_config(:secret_token) do
      nil ->
        # No secret token configured — skip verification
        :ok

      "" ->
        :ok

      expected_token ->
        case get_req_header(conn, "x-telegram-bot-api-secret-token") do
          [^expected_token] -> :ok
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp channel_config(key) do
    case Loomkin.Config.get(:channels) do
      %{telegram: %{} = telegram} -> Map.get(telegram, key)
      _ -> nil
    end
  end

  defp handle_update(conn, update) do
    # Extract chat_id from the update to look up the binding
    channel_id = extract_chat_id(update)

    if channel_id do
      channel_id_str = to_string(channel_id)

      # Dispatch via Task.Supervisor so errors are logged and Ecto sandbox works in tests
      Task.Supervisor.start_child(Loomkin.Channels.WebhookTaskSupervisor, fn ->
        case ChannelRouter.handle_inbound(
               Loomkin.Channels.Telegram.Adapter,
               :telegram,
               channel_id_str,
               update
             ) do
          {:ok, response} when is_binary(response) ->
            # Command responses need to be sent back to the chat
            telegex().send_message(channel_id_str, response)

          {:ok, _} ->
            :ok

          {:error, :no_binding} ->
            :ok

          {:error, _reason} ->
            :ok
        end
      end)
    else
      :ok
    end

    # Always respond 200 OK to Telegram to prevent retries
    send_resp(conn, 200, "ok")
  end

  defp telegex, do: Application.get_env(:loomkin, :telegex_module, Telegex)

  defp extract_chat_id(update) do
    cond do
      chat_id = get_in(update, ["message", "chat", "id"]) -> chat_id
      chat_id = get_in(update, ["edited_message", "chat", "id"]) -> chat_id
      chat_id = get_in(update, ["callback_query", "message", "chat", "id"]) -> chat_id
      true -> nil
    end
  end
end
