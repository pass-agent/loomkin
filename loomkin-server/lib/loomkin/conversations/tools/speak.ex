defmodule Loomkin.Conversations.Tools.Speak do
  @moduledoc "Submit dialogue content to the conversation."

  use Jido.Action,
    name: "speak",
    description: "Submit your dialogue contribution to the conversation.",
    schema: [
      content: [type: :string, required: true, doc: "Your dialogue content (2-4 sentences ideal)"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Conversations.Server

  @impl true
  def run(params, context) do
    conversation_id = param!(context, :conversation_id)
    agent_name = param!(context, :agent_name)
    content = param!(params, :content)

    case Server.speak(conversation_id, agent_name, content) do
      :ok -> {:ok, %{result: "Spoke in conversation."}}
      {:error, reason} -> {:error, "Failed to speak: #{inspect(reason)}"}
    end
  end
end
