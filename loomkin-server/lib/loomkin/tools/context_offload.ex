defmodule Loomkin.Tools.ContextOffload do
  @moduledoc "Offload conversation context to a keeper process."

  use Jido.Action,
    name: "context_offload",
    description:
      "Offload a chunk of your conversation context to a keeper process. " <>
        "Use when you've accumulated extensive context on a topic and want to free up " <>
        "your context window while preserving the information for later retrieval. " <>
        "The offloaded context remains queryable via context_retrieve.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      topic: [type: :string, required: true, doc: "Short topic label for the offloaded context"],
      message_count: [type: :integer, doc: "Number of oldest messages to offload (default: auto)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.ContextOffload

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    topic = param!(params, :topic)
    message_count = param(params, :message_count)
    agent_name = param!(context, :agent_name)

    # Messages are injected into context by the on_tool_execute callback in agent.ex
    # to avoid a deadlock (the tool runs inside the agent's GenServer call chain).
    messages = param!(context, :agent_messages)

    {offload_msgs, _keep_msgs} =
      if message_count do
        Enum.split(messages, message_count)
      else
        ContextOffload.split_at_topic_boundary(messages)
      end

    if offload_msgs == [] do
      {:ok, %{result: "No messages to offload (context too small)."}}
    else
      case ContextOffload.offload_to_keeper(team_id, agent_name, offload_msgs, topic: topic) do
        {:ok, _pid, index_entry} ->
          {:ok, %{result: "Offloaded #{length(offload_msgs)} messages. #{index_entry}"}}

        {:error, reason} ->
          {:error, "Failed to offload: #{inspect(reason)}"}
      end
    end
  end
end
