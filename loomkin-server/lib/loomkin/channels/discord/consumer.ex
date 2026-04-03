defmodule Loomkin.Channels.Discord.Consumer do
  @moduledoc """
  Nostrum consumer that handles Discord gateway events and routes them
  to the channel router.

  Handles MESSAGE_CREATE for regular messages and INTERACTION_CREATE
  for button callbacks (ask_user responses).

  When Nostrum is loaded, uses `Nostrum.Consumer` which auto-joins the
  ConsumerGroup and dispatches events to `handle_event/1`. Otherwise
  falls back to a plain GenServer (for compilation in test environments).
  """

  alias Loomkin.Channels.Router

  @adapter Loomkin.Channels.Discord.Adapter

  # Use Nostrum.Consumer if available, otherwise fall back to GenServer
  # so the module compiles even when Nostrum isn't loaded (e.g., in tests).
  if Code.ensure_loaded?(Nostrum.Consumer) do
    use Nostrum.Consumer
  else
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      {:ok, %{}}
    end
  end

  @doc """
  Handle a Discord gateway event.

  Called by Nostrum's consumer pipeline or directly in tests.
  """
  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    # Skip messages from the bot itself
    bot_id = get_bot_id()

    if Map.get(msg.author, :id) == bot_id do
      :ok
    else
      channel_id = to_string(msg.channel_id)

      event = %{
        type: :MESSAGE_CREATE,
        content: msg.content,
        id: msg.id,
        channel_id: msg.channel_id,
        guild_id: Map.get(msg, :guild_id),
        author: %{
          id: msg.author.id,
          username: msg.author.username
        },
        bot: Map.get(msg.author, :bot, false)
      }

      case Router.handle_inbound(@adapter, :discord, channel_id, event) do
        {:ok, response} when is_binary(response) ->
          nostrum_api().create_message(msg.channel_id, content: response)

        _ ->
          :ok
      end
    end
  end

  def handle_event({:INTERACTION_CREATE, interaction, _ws_state}) do
    # Handle button interactions (ask_user callbacks)
    custom_id = get_in(interaction, [:data, :custom_id]) || ""
    channel_id = to_string(interaction.channel_id)

    event = %{
      type: :INTERACTION_CREATE,
      data: %{custom_id: custom_id},
      channel_id: interaction.channel_id,
      guild_id: Map.get(interaction, :guild_id),
      token: interaction.token,
      id: interaction.id,
      member: Map.get(interaction, :member),
      user: Map.get(interaction, :user)
    }

    case Router.handle_inbound(@adapter, :discord, channel_id, event) do
      {:ok, _} ->
        # Acknowledge the interaction
        nostrum_api().create_interaction_response(interaction, %{
          type: 7,
          data: %{content: "Answer recorded.", flags: 64}
        })

      {:error, _} ->
        nostrum_api().create_interaction_response(interaction, %{
          type: 4,
          data: %{content: "Something went wrong.", flags: 64}
        })
    end
  end

  def handle_event({_event_type, _data, _ws_state}), do: :ok

  # --- Private ---

  defp get_bot_id do
    if Code.ensure_loaded?(Nostrum.Cache.Me) do
      case apply(Nostrum.Cache.Me, :get, []) do
        %{id: id} -> id
        _ -> nil
      end
    else
      nil
    end
  end

  defp nostrum_api do
    Application.get_env(:loomkin, :nostrum_api, Nostrum.Api)
  end
end
