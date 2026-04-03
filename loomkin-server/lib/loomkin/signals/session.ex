defmodule Loomkin.Signals.Session do
  @moduledoc "Session-domain signals: new messages, status changes."

  defmodule NewMessage do
    use Jido.Signal,
      type: "session.message.new",
      schema: [
        session_id: [type: :string, required: true]
      ]
  end

  defmodule StatusChanged do
    use Jido.Signal,
      type: "session.status.changed",
      schema: [
        session_id: [type: :string, required: true],
        status: [type: :atom, required: true]
      ]
  end

  defmodule Cancelled do
    use Jido.Signal,
      type: "session.cancelled",
      schema: [
        session_id: [type: :string, required: true]
      ]
  end

  defmodule PermissionRequest do
    use Jido.Signal,
      type: "session.permission.request",
      schema: [
        session_id: [type: :string, required: true],
        tool_name: [type: :string, required: true],
        tool_path: [type: :string, required: false]
      ]
  end

  defmodule TeamAvailable do
    use Jido.Signal,
      type: "session.team.available",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule ChildTeamAvailable do
    use Jido.Signal,
      type: "session.child_team.available",
      schema: [
        session_id: [type: :string, required: true],
        child_team_id: [type: :string, required: true]
      ]
  end

  defmodule LlmError do
    use Jido.Signal,
      type: "session.llm.error",
      schema: [
        session_id: [type: :string, required: true],
        error: [type: :string, required: false]
      ]
  end
end
