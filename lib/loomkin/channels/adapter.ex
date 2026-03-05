defmodule Loomkin.Channels.Adapter do
  @moduledoc """
  Behaviour for channel adapters (Telegram, Discord, etc.).

  Each adapter normalizes platform-specific message formats into a common
  internal format and implements sending outbound messages via the platform API.
  """

  alias Loomkin.Channels.Message

  @type binding :: map()
  @type opts :: keyword()
  @type event :: map()

  @doc "Send a plain text message to the bound channel."
  @callback send_text(binding, text :: String.t(), opts) :: :ok | {:error, term()}

  @doc """
  Send an `ask_user` question with selectable options.

  Maps to inline keyboards (Telegram) or button components (Discord).
  The `question_id` must be embedded in callback data so that inbound
  callbacks can be matched back to the pending question in the Bridge.
  """
  @callback send_question(
              binding,
              question_id :: String.t(),
              question :: String.t(),
              options :: [String.t()]
            ) ::
              :ok | {:error, term()}

  @doc "Send an agent activity event (tool use, status change, etc.) to the channel."
  @callback send_activity(binding, event) :: :ok | {:error, term()}

  @doc "Format an agent's message for display in the channel."
  @callback format_agent_message(agent_name :: String.t(), content :: String.t()) :: String.t()

  @doc """
  Parse a raw inbound event from the platform into a normalized form.

  Returns:
  - `{:message, text, metadata}` for regular messages
  - `{:callback, callback_id, data}` for button/keyboard callbacks (ask_user answers)
  - `:ignore` for events that should be skipped
  """
  @callback parse_inbound(raw_event :: term()) ::
              {:message, String.t(), Message.metadata()}
              | {:callback, String.t(), term()}
              | :ignore
end
