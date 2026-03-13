defmodule Loomkin.Conversations.Tools.React do
  @moduledoc "Submit a short reaction without taking a full turn."

  use Jido.Action,
    name: "react",
    description:
      "Submit a short reaction (agree, disagree, question, laugh, think) " <>
        "without consuming your full turn.",
    schema: [
      type: [
        type: :string,
        required: true,
        doc: "Reaction type: agree, disagree, question, laugh, or think"
      ],
      brief: [type: :string, required: true, doc: "Brief text for the reaction"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  alias Loomkin.Conversations.Server

  @valid_types ~w[agree disagree question laugh think]

  @impl true
  def run(params, context) do
    conversation_id = param!(context, :conversation_id)
    agent_name = param!(context, :agent_name)
    type_str = param!(params, :type)
    brief = param!(params, :brief)

    if type_str in @valid_types do
      type = String.to_existing_atom(type_str)

      case Server.react(conversation_id, agent_name, type, brief) do
        :ok -> {:ok, %{result: "Reacted with #{type_str}."}}
        {:error, reason} -> {:error, "Failed to react: #{inspect(reason)}"}
      end
    else
      {:error,
       "Invalid reaction type: #{type_str}. Must be one of: #{Enum.join(@valid_types, ", ")}"}
    end
  end
end
