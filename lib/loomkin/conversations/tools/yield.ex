defmodule Loomkin.Conversations.Tools.Yield do
  @moduledoc "Pass your turn when you have nothing meaningful to add."

  use Jido.Action,
    name: "yield",
    description: "Pass your turn. Use when you have nothing meaningful to add right now.",
    schema: [
      reason: [type: :string, required: false, doc: "Optional reason for yielding"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Conversations.Server

  @impl true
  def run(params, context) do
    conversation_id = param!(context, :conversation_id)
    agent_name = param!(context, :agent_name)
    reason = param(params, :reason)

    case Server.yield(conversation_id, agent_name, reason) do
      :ok -> {:ok, %{result: "Yielded turn."}}
      {:error, reason} -> {:error, "Failed to yield: #{inspect(reason)}"}
    end
  end
end
