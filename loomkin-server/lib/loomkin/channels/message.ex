defmodule Loomkin.Channels.Message do
  @moduledoc """
  Common message struct for channel communication.

  Represents both inbound (from channel to Loomkin) and outbound
  (from Loomkin to channel) messages in a normalized format.
  """

  @type direction :: :inbound | :outbound
  @type channel :: :telegram | :discord | :web

  @type metadata :: %{optional(atom()) => term()}

  @type t :: %__MODULE__{
          direction: direction(),
          channel: channel(),
          binding_id: String.t() | nil,
          sender: String.t() | nil,
          content: String.t() | nil,
          metadata: metadata(),
          timestamp: DateTime.t()
        }

  @enforce_keys [:direction, :channel]
  defstruct [
    :direction,
    :channel,
    :binding_id,
    :sender,
    :content,
    metadata: %{},
    timestamp: nil
  ]

  @doc "Build a new inbound message."
  @spec inbound(channel(), String.t(), String.t(), metadata()) :: t()
  def inbound(channel, sender, content, metadata \\ %{}) do
    %__MODULE__{
      direction: :inbound,
      channel: channel,
      sender: sender,
      content: content,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Build a new outbound message."
  @spec outbound(channel(), String.t(), String.t(), metadata()) :: t()
  def outbound(channel, binding_id, content, metadata \\ %{}) do
    %__MODULE__{
      direction: :outbound,
      channel: channel,
      binding_id: binding_id,
      content: content,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }
  end
end
