defmodule Loomkin.Channels.TelegexBehaviour do
  @moduledoc """
  Behaviour defining the Telegex API surface used by the Telegram adapter.

  This allows Mox-based testing without hitting the real Telegram API.
  """

  @callback send_message(chat_id :: term(), text :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback answer_callback_query(callback_query_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @callback get_updates(opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}
end
