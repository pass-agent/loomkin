defmodule Loomkin.Relay.Protocol.Register do
  @moduledoc "Sent by daemon on connect to announce its machine and active workspaces."

  @type t :: %__MODULE__{
          machine_name: String.t(),
          version: String.t(),
          workspaces: [workspace_info()]
        }

  @type workspace_info :: %{
          id: String.t(),
          name: String.t(),
          project_path: String.t(),
          team_id: String.t() | nil,
          status: String.t(),
          agent_count: non_neg_integer()
        }

  defstruct [:machine_name, :version, workspaces: []]

  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "register",
      "machine_name" => msg.machine_name,
      "version" => msg.version,
      "workspaces" =>
        Enum.map(msg.workspaces, fn ws ->
          %{
            "id" => ws.id,
            "name" => ws.name,
            "project_path" => ws.project_path,
            "team_id" => ws.team_id,
            "status" => to_string(ws.status),
            "agent_count" => ws.agent_count
          }
        end)
    }
  end

  def from_map(%{"type" => "register"} = map) do
    %__MODULE__{
      machine_name: map["machine_name"],
      version: map["version"],
      workspaces:
        Enum.map(map["workspaces"] || [], fn ws ->
          %{
            id: ws["id"],
            name: ws["name"],
            project_path: ws["project_path"],
            team_id: ws["team_id"],
            status: ws["status"],
            agent_count: ws["agent_count"] || 0
          }
        end)
    }
  end
end
