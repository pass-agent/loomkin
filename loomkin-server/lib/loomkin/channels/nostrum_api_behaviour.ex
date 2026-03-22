defmodule Loomkin.Channels.NostrumApiBehaviour do
  @moduledoc """
  Behaviour defining the Nostrum.Api surface used by the Discord adapter.

  This allows Mox-based testing without hitting the real Discord API.
  """

  @callback create_message(channel_id :: integer(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
