defmodule Loomkin.Signals.Decision do
  @moduledoc "Decision graph signals: node added, pivot created, decision logged."

  defmodule NodeAdded do
    use Jido.Signal,
      type: "decision.node.added",
      schema: [
        team_id: [type: :string, required: false]
      ]
  end

  defmodule PivotCreated do
    use Jido.Signal,
      type: "decision.pivot.created",
      schema: [
        team_id: [type: :string, required: false]
      ]
  end

  defmodule DecisionLogged do
    use Jido.Signal,
      type: "decision.logged",
      schema: [
        node_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end
end
