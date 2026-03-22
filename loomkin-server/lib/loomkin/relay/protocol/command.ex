defmodule Loomkin.Relay.Protocol.Command do
  @moduledoc """
  Sent by cloud to daemon to relay a command from a mobile client.

  ## Actions

  - `send_message` — send user text to a session (payload: `%{"text" => "..."}`)
  - `cancel` — cancel running agent task
  - `get_history` — fetch message history (payload: `%{"limit" => 50, "offset" => 0}`)
  - `get_status` — get session status
  - `approve_tool` — approve pending tool execution (payload: `%{"tool_name" => "...", "tool_path" => "..."}`)
  - `deny_tool` — deny pending tool execution (payload: `%{"tool_name" => "...", "reason" => "..."}`)
  - `get_agents` — list agent roster (payload: `%{"team_id" => "..."}`)
  - `pause_agent` — pause a running agent (payload: `%{"agent_name" => "...", "team_id" => "..."}`)
  - `resume_agent` — resume a paused agent
  - `steer_agent` — send guidance to paused agent (payload: `%{"agent_name" => "...", "team_id" => "...", "guidance" => "..."}`)
  - `change_model` — switch the session model (payload: `%{"model" => "..."}`)
  - `kill_team` — terminate all agents in a team (payload: `%{"team_id" => "...", "confirm" => true}`)
  """

  @type t :: %__MODULE__{
          request_id: String.t(),
          action: String.t(),
          workspace_id: String.t(),
          session_id: String.t() | nil,
          payload: map()
        }

  defstruct [:request_id, :action, :workspace_id, :session_id, payload: %{}]

  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "command",
      "request_id" => msg.request_id,
      "action" => msg.action,
      "workspace_id" => msg.workspace_id,
      "session_id" => msg.session_id,
      "payload" => msg.payload
    }
  end

  def from_map(%{"type" => "command"} = map) do
    %__MODULE__{
      request_id: map["request_id"],
      action: map["action"],
      workspace_id: map["workspace_id"],
      session_id: map["session_id"],
      payload: map["payload"] || %{}
    }
  end
end
