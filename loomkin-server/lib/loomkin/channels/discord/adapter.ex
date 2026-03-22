defmodule Loomkin.Channels.Discord.Adapter do
  @moduledoc """
  Discord adapter implementing the `Loomkin.Channels.Adapter` behaviour.

  Uses the Nostrum library for Discord API interactions. Sends messages,
  embeds, and button components to Discord channels.
  """

  @behaviour Loomkin.Channels.Adapter

  alias Loomkin.Channels.Discord.Formatter

  @impl true
  def send_text(binding, text, _opts) do
    channel_id = String.to_integer(binding.channel_id)

    Formatter.split_message(text)
    |> Enum.each(fn chunk ->
      nostrum_api().create_message(channel_id, content: chunk)
    end)

    :ok
  rescue
    e ->
      {:error, e}
  end

  @impl true
  def send_question(binding, question_id, question, options) do
    channel_id = String.to_integer(binding.channel_id)
    components = Formatter.question_buttons(question_id, options)

    nostrum_api().create_message(channel_id,
      content: question,
      components: components
    )

    :ok
  rescue
    e ->
      {:error, e}
  end

  @impl true
  def send_activity(binding, event) do
    channel_id = String.to_integer(binding.channel_id)

    title = Map.get(event, :type, :activity) |> to_string() |> String.replace("_", " ")
    description = Map.get(event, :summary, inspect(event))
    role = Map.get(event, :agent_role, :default)
    embed = Formatter.activity_embed(title, description, role)

    nostrum_api().create_message(channel_id, embeds: [embed])
    :ok
  rescue
    e ->
      {:error, e}
  end

  @impl true
  def format_agent_message(agent_name, content) do
    Formatter.format_agent_message(agent_name, content)
  end

  @impl true
  def parse_inbound(%{type: :MESSAGE_CREATE} = event) do
    # Skip bot messages
    if Map.get(event, :bot, false) do
      :ignore
    else
      content = Map.get(event, :content, "")
      _author = get_in(event, [:author, :username]) || "unknown"

      metadata = %{
        discord_message_id: Map.get(event, :id),
        discord_channel_id: Map.get(event, :channel_id),
        guild_id: Map.get(event, :guild_id),
        user_id: get_in(event, [:author, :id])
      }

      {:message, content, metadata}
    end
  end

  def parse_inbound(%{type: :INTERACTION_CREATE, data: data} = event) do
    custom_id = Map.get(data, :custom_id, "")

    case String.split(custom_id, ":", parts: 3) do
      ["ask_user", question_id, index_str] ->
        # Resolve the selected option label from the interaction
        {idx, _} = Integer.parse(index_str)
        user_id = get_in(event, [:member, :user, :id]) || get_in(event, [:user, :id])
        {:callback, question_id, %{index: idx, interaction: event, user_id: user_id}}

      _ ->
        :ignore
    end
  end

  def parse_inbound(_), do: :ignore

  # --- Private ---

  defp nostrum_api do
    Application.get_env(:loomkin, :nostrum_api, Nostrum.Api)
  end
end
