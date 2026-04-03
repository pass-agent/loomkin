defmodule Loomkin.Signals.Agent do
  @moduledoc "Agent-domain signals: streaming, tool execution, errors, escalation, usage."

  defmodule StreamStart do
    use Jido.Signal,
      type: "agent.stream.start",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule StreamDelta do
    use Jido.Signal,
      type: "agent.stream.delta",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        content: [type: :string, required: false]
      ]
  end

  defmodule StreamEnd do
    use Jido.Signal,
      type: "agent.stream.end",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule ToolExecuting do
    use Jido.Signal,
      type: "agent.tool.executing",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        tool_name: [type: :string, required: false]
      ]
  end

  defmodule ToolComplete do
    use Jido.Signal,
      type: "agent.tool.complete",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        tool_name: [type: :string, required: false]
      ]
  end

  defmodule Error do
    use Jido.Signal,
      type: "agent.error",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        reason: [type: :string, required: false]
      ]
  end

  defmodule Escalation do
    use Jido.Signal,
      type: "agent.escalation",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        from_model: [type: :string, required: true],
        to_model: [type: :string, required: true]
      ]
  end

  defmodule Usage do
    use Jido.Signal,
      type: "agent.usage",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule Status do
    use Jido.Signal,
      type: "agent.status",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        status: [type: :atom, required: true],
        previous_status: [type: :atom, required: false],
        pause_queued: [type: :boolean, required: false]
      ]
  end

  defmodule RoleChanged do
    use Jido.Signal,
      type: "agent.role.changed",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        old_role: [type: :atom, required: true],
        new_role: [type: :atom, required: true]
      ]
  end

  defmodule QueueUpdated do
    use Jido.Signal,
      type: "agent.queue.updated",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule Crashed do
    use Jido.Signal,
      type: "agent.crashed",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        reason: [type: :string, required: false],
        crash_count: [type: :integer, required: false]
      ]
  end

  defmodule Recovered do
    use Jido.Signal,
      type: "agent.recovered",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        crash_count: [type: :integer, required: false]
      ]
  end

  defmodule PermanentlyFailed do
    use Jido.Signal,
      type: "agent.permanently_failed",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        crash_count: [type: :integer, required: false]
      ]
  end

  defmodule Ready do
    use Jido.Signal,
      type: "agent.ready",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        ready_for: [type: :string, required: false],
        task_id: [type: :string, required: false],
        rendezvous_id: [type: :string, required: false]
      ]
  end

  defmodule HealingRequested do
    use Jido.Signal,
      type: "agent.healing.requested",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        classification: [type: :map, required: true],
        error_context: [type: :map, required: false]
      ]
  end

  defmodule HealingComplete do
    use Jido.Signal,
      type: "agent.healing.complete",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        healing_summary: [type: :map, required: true]
      ]
  end

  defmodule ScopeGate do
    use Jido.Signal,
      type: "agent.scope_gate",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true],
        tier: [type: :atom, required: true],
        trigger: [type: :atom, required: true]
      ]
  end
end
