defmodule Loomkin.Relay.Protocol.WorkspaceUpdate do
  @moduledoc """
  Sent by daemon when a workspace's state changes (new workspace started,
  workspace hibernated, agent count changed, etc.).

  The cloud updates its registry so mobile clients see current state.
  """

  @type t :: %__MODULE__{
          workspace_id: String.t(),
          name: String.t() | nil,
          project_path: String.t() | nil,
          team_id: String.t() | nil,
          status: String.t(),
          agent_count: non_neg_integer()
        }

  defstruct [:workspace_id, :name, :project_path, :team_id, :status, agent_count: 0]

  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "workspace_update",
      "workspace_id" => msg.workspace_id,
      "name" => msg.name,
      "project_path" => msg.project_path,
      "team_id" => msg.team_id,
      "status" => msg.status,
      "agent_count" => msg.agent_count
    }
  end

  def from_map(%{"type" => "workspace_update"} = map) do
    %__MODULE__{
      workspace_id: map["workspace_id"],
      name: map["name"],
      project_path: map["project_path"],
      team_id: map["team_id"],
      status: map["status"],
      agent_count: map["agent_count"] || 0
    }
  end
end
