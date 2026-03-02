defmodule Loomkin.Tools.DecisionLog do
  @moduledoc "Tool for logging decisions, goals, actions, and observations to the decision graph."

  use Jido.Action,
    name: "decision_log",
    description:
      "Log a decision, goal, action, or observation to the decision graph for persistent context",
    schema: [
      node_type: [type: :string, required: true, doc: "Type of decision node (goal, decision, option, action, outcome, observation, revisit)"],
      title: [type: :string, required: true, doc: "Short title for this node"],
      description: [type: :string, doc: "Detailed description"],
      confidence: [type: :integer, doc: "Confidence level 0-100"],
      parent_id: [type: :string, doc: "ID of parent node to connect via edge"],
      edge_type: [type: :string, doc: "Edge type to parent (default: leads_to)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2, param: 3]

  alias Loomkin.Decisions.Graph

  @valid_node_types ~w(goal decision option action outcome observation revisit)

  @impl true
  def run(params, context) do
    raw_type = param!(params, :node_type)

    if raw_type in @valid_node_types do
      do_run(raw_type, params, context)
    else
      {:error, "Invalid node_type: #{raw_type}. Must be one of: #{Enum.join(@valid_node_types, ", ")}"}
    end
  end

  defp do_run(raw_type, params, context) do
    node_type = String.to_existing_atom(raw_type)
    title = param!(params, :title)

    attrs = %{
      node_type: node_type,
      title: title,
      description: param(params, :description),
      confidence: param(params, :confidence),
      session_id: param(context, :session_id)
    }

    case Graph.add_node(attrs) do
      {:ok, node} ->
        maybe_create_edge(node, params)

      {:error, changeset} ->
        {:error, "Failed to log decision: #{inspect(changeset.errors)}"}
    end
  end

  defp maybe_create_edge(node, params) do
    case param(params, :parent_id) do
      nil ->
        {:ok, %{result: "Logged #{node.node_type}: #{node.title} (id: #{node.id})"}}

      parent_id ->
        edge_type =
          param(params, :edge_type, "leads_to") |> String.to_existing_atom()

        case Graph.add_edge(parent_id, node.id, edge_type) do
          {:ok, _edge} ->
            {:ok,
             %{result: "Logged #{node.node_type}: #{node.title} (id: #{node.id}), linked to #{parent_id} via #{edge_type}"}}

          {:error, changeset} ->
            {:ok,
             %{result: "Logged #{node.node_type}: #{node.title} (id: #{node.id}), but edge creation failed: #{inspect(changeset.errors)}"}}
        end
    end
  end
end
