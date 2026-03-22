defmodule Loomkin.Relay.Protocol.Event do
  @moduledoc """
  Sent by daemon to cloud to stream real-time events to mobile clients.

  Events originate from the local signal bus (Loomkin.Signals) and are
  forwarded through the relay to subscribed client WebSocket channels.

  The `event_type` mirrors the Jido signal type (e.g. "agent.stream.delta",
  "session.status_changed", "team.permission.request").
  """

  @type t :: %__MODULE__{
          workspace_id: String.t(),
          session_id: String.t() | nil,
          team_id: String.t() | nil,
          event_type: String.t(),
          data: map()
        }

  defstruct [:workspace_id, :session_id, :team_id, :event_type, data: %{}]

  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "event",
      "workspace_id" => msg.workspace_id,
      "session_id" => msg.session_id,
      "team_id" => msg.team_id,
      "event_type" => msg.event_type,
      "data" => msg.data
    }
  end

  def from_map(%{"type" => "event"} = map) do
    %__MODULE__{
      workspace_id: map["workspace_id"],
      session_id: map["session_id"],
      team_id: map["team_id"],
      event_type: map["event_type"],
      data: map["data"] || %{}
    }
  end
end
