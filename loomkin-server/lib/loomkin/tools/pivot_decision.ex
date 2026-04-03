defmodule Loomkin.Tools.PivotDecision do
  @moduledoc "Tool for creating a pivot chain in the decision graph."

  use Jido.Action,
    name: "pivot_decision",
    description:
      "Pivot away from an existing decision/goal by creating an observation, revisit, and new approach. " <>
        "Supersedes the old node atomically.",
    schema: [
      old_node_id: [
        type: :string,
        required: true,
        doc: "ID of the active node to pivot away from"
      ],
      observation: [
        type: :string,
        required: true,
        doc: "What was observed that triggered the pivot"
      ],
      new_approach: [
        type: :string,
        required: true,
        doc: "Title of the new approach/decision"
      ],
      confidence: [type: :integer, doc: "Confidence level 0-100 for the new decision"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Decisions.Graph

  @impl true
  def run(params, context) do
    old_node_id = param!(params, :old_node_id)
    observation = param!(params, :observation)
    new_approach = param!(params, :new_approach)

    opts =
      [
        agent_name: param(context, :agent_name),
        confidence: param(params, :confidence),
        metadata:
          %{}
          |> maybe_put("team_id", param(context, :team_id))
          |> maybe_put("keeper_id", param(context, :keeper_id))
      ]

    case Graph.create_pivot_chain(old_node_id, observation, new_approach, opts) do
      {:ok, result} ->
        {:ok,
         %{
           result:
             "Pivot created: #{result.old_node.title} -> #{result.observation.title} -> " <>
               "#{result.revisit.title} -> #{result.decision.title} (id: #{result.decision.id})"
         }}

      {:error, :old_node_not_found} ->
        {:error, "Node #{old_node_id} not found"}

      {:error, :old_node_not_active} ->
        {:error, "Node #{old_node_id} is not active (already superseded or abandoned)"}

      {:error, reason} ->
        {:error, "Pivot failed: #{inspect(reason)}"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
