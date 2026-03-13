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

  @impl true
  def run(params, context) do
    conversation_id = param!(context, :conversation_id)
    agent_name = param!(context, :agent_name)
    type_str = param!(params, :type)
    brief = param!(params, :brief)

    case reaction_type(type_str) do
      {:ok, type} ->
        case Server.react(conversation_id, agent_name, type, brief) do
          :ok -> {:ok, %{result: "Reacted with #{type_str}."}}
          {:error, err} -> {:error, "Failed to react: #{inspect(err)}"}
        end

      :error ->
        {:error,
         "Invalid reaction type: #{type_str}. Must be one of: agree, disagree, question, laugh, think"}
    end
  end

  defp reaction_type("agree"), do: {:ok, :agree}
  defp reaction_type("disagree"), do: {:ok, :disagree}
  defp reaction_type("question"), do: {:ok, :question}
  defp reaction_type("laugh"), do: {:ok, :laugh}
  defp reaction_type("think"), do: {:ok, :think}
  defp reaction_type(_), do: :error
end
