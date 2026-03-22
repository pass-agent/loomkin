defmodule Loomkin.Channels.Supervisor do
  @moduledoc """
  Supervises channel adapter processes and the bridge supervisor.

  Only starts channel-specific children (Telegram webhook/poller, Discord consumer)
  when their respective configs are enabled.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [
        Loomkin.Channels.AuditLog,
        Loomkin.Channels.BridgeSupervisor,
        {Task.Supervisor, name: Loomkin.Channels.WebhookTaskSupervisor}
      ] ++ telegram_children() ++ discord_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp telegram_children do
    config = Loomkin.Config.get(:channels, :telegram) || %{}

    if config[:enabled] do
      maybe_auto_bind_telegram(config)

      case to_string(config[:mode] || "webhook") do
        "polling" ->
          [Loomkin.Channels.Telegram.Poller]

        _webhook ->
          # Webhook is a Plug — started as part of the Phoenix endpoint router,
          # not as a standalone child. Nothing to add here for Telegram beyond
          # the bridge supervisor which is already started above.
          []
      end
    else
      []
    end
  end

  defp discord_children do
    config = Loomkin.Config.get(:channels, :discord) || %{}

    if config[:enabled] do
      [Loomkin.Channels.Discord.Consumer]
    else
      []
    end
  end

  # When a chat_id is configured, auto-create a binding so that
  # the bot starts forwarding events to that chat immediately.
  defp maybe_auto_bind_telegram(config) do
    chat_id = config[:chat_id]

    if chat_id && chat_id != "" do
      chat_id_str = to_string(chat_id)

      # Use a default team_id placeholder — binding activates when a team starts
      case Loomkin.Channels.Bindings.find_or_create(:telegram, chat_id_str, "default") do
        {:ok, _binding} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end
  end
end
