defmodule Loomkin.Conversations.Tools.EndConversation do
  @moduledoc "Propose ending the conversation."

  use Jido.Action,
    name: "end_conversation",
    description:
      "Propose ending the conversation. Available to the facilitator, " <>
        "or when there is consensus to stop.",
    schema: [
      reason: [type: :string, required: true, doc: "Why you want to end the conversation"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Conversations.Server

  @impl true
  def run(params, context) do
    conversation_id = param!(context, :conversation_id)
    agent_name = param!(context, :agent_name)
    reason = param!(params, :reason)

    case Server.terminate_conversation(conversation_id, {:requested_by, agent_name, reason}) do
      :ok -> {:ok, %{result: "Conversation ended."}}
      {:error, err} -> {:error, "Failed to end conversation: #{inspect(err)}"}
    end
  end
end
