defmodule Loomkin.Relay.Client.CommandHandler do
  @moduledoc """
  Dispatches relay commands to existing Loomkin modules.

  Each `handle/1` clause maps a `Command` action to the appropriate
  Session, Teams.Agent, or Teams.Manager API and returns a
  `CommandResponse` struct.
  """

  require Logger

  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Protocol.CommandResponse
  alias Loomkin.Session
  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.Manager

  @doc "Dispatch a command and return the corresponding CommandResponse."
  @spec handle(Command.t()) :: CommandResponse.t()
  def handle(%Command{action: "send_message"} = cmd) do
    case Session.send_message(cmd.session_id, cmd.payload["text"] || "") do
      {:ok, response} ->
        CommandResponse.ok(cmd.request_id, %{"response" => response})

      {:error, reason} ->
        CommandResponse.error(cmd.request_id, format_error(reason))
    end
  end

  def handle(%Command{action: "cancel"} = cmd) do
    case Session.cancel(cmd.session_id) do
      :ok ->
        CommandResponse.ok(cmd.request_id)

      {:error, reason} ->
        CommandResponse.error(cmd.request_id, format_error(reason))
    end
  end

  def handle(%Command{action: "get_history"} = cmd) do
    case Session.get_history(cmd.session_id) do
      {:ok, messages} ->
        CommandResponse.ok(cmd.request_id, %{"messages" => messages})

      {:error, reason} ->
        CommandResponse.error(cmd.request_id, format_error(reason))
    end
  end

  def handle(%Command{action: "get_status"} = cmd) do
    case Session.get_status(cmd.session_id) do
      {:ok, status} ->
        CommandResponse.ok(cmd.request_id, %{"status" => to_string(status)})

      {:error, reason} ->
        CommandResponse.error(cmd.request_id, format_error(reason))
    end
  end

  def handle(%Command{action: "approve_tool"} = cmd) do
    tool_name = cmd.payload["tool_name"]
    tool_path = cmd.payload["tool_path"] || ""

    case Session.permission_response(cmd.session_id, "allow_once", tool_name, tool_path) do
      :ok ->
        CommandResponse.ok(cmd.request_id)

      {:error, reason} ->
        CommandResponse.error(cmd.request_id, format_error(reason))
    end
  end

  def handle(%Command{action: "deny_tool"} = cmd) do
    tool_name = cmd.payload["tool_name"]
    tool_path = cmd.payload["tool_path"] || ""

    case Session.permission_response(cmd.session_id, "deny", tool_name, tool_path) do
      :ok ->
        CommandResponse.ok(cmd.request_id)

      {:error, reason} ->
        CommandResponse.error(cmd.request_id, format_error(reason))
    end
  end

  def handle(%Command{action: "get_agents"} = cmd) do
    team_id = cmd.payload["team_id"]

    if is_nil(team_id) do
      CommandResponse.error(cmd.request_id, "team_id required")
    else
      agents =
        team_id
        |> Manager.list_agents()
        |> Enum.map(fn agent ->
          %{
            "name" => agent.name,
            "role" => to_string(agent.role),
            "status" => to_string(agent.status),
            "model" => agent.model
          }
        end)

      CommandResponse.ok(cmd.request_id, %{"agents" => agents})
    end
  end

  def handle(%Command{action: "pause_agent"} = cmd) do
    with {:ok, team_id, agent_name} <- extract_agent_params(cmd) do
      case Manager.find_agent(team_id, agent_name) do
        {:ok, pid} ->
          Agent.request_pause(pid)
          CommandResponse.ok(cmd.request_id)

        :error ->
          CommandResponse.error(cmd.request_id, "agent not found: #{agent_name}")
      end
    end
  end

  def handle(%Command{action: "resume_agent"} = cmd) do
    with {:ok, team_id, agent_name} <- extract_agent_params(cmd) do
      guidance = cmd.payload["guidance"]

      case Manager.find_agent(team_id, agent_name) do
        {:ok, pid} ->
          opts = if guidance, do: [guidance: guidance], else: []
          Agent.resume(pid, opts)
          CommandResponse.ok(cmd.request_id)

        :error ->
          CommandResponse.error(cmd.request_id, "agent not found: #{agent_name}")
      end
    end
  end

  def handle(%Command{action: "steer_agent"} = cmd) do
    with {:ok, team_id, agent_name} <- extract_agent_params(cmd) do
      guidance = cmd.payload["guidance"] || ""

      case Manager.find_agent(team_id, agent_name) do
        {:ok, pid} ->
          Agent.steer(pid, guidance)
          CommandResponse.ok(cmd.request_id)

        :error ->
          CommandResponse.error(cmd.request_id, "agent not found: #{agent_name}")
      end
    end
  end

  def handle(%Command{action: "change_model"} = cmd) do
    model = cmd.payload["model"]

    case Session.update_model(cmd.session_id, model) do
      :ok ->
        CommandResponse.ok(cmd.request_id)

      {:error, reason} ->
        CommandResponse.error(cmd.request_id, format_error(reason))
    end
  end

  def handle(%Command{action: "kill_team"} = cmd) do
    team_id = cmd.payload["team_id"]

    cond do
      is_nil(team_id) ->
        CommandResponse.error(cmd.request_id, "team_id required")

      !cmd.payload["confirm"] ->
        CommandResponse.error(cmd.request_id, "kill_team requires confirm: true")

      true ->
        Manager.dissolve_team(team_id)
        CommandResponse.ok(cmd.request_id)
    end
  end

  def handle(%Command{} = cmd) do
    Logger.warning("[Relay:cmd] unknown action=#{cmd.action} request_id=#{cmd.request_id}")
    CommandResponse.error(cmd.request_id, "unknown action: #{cmd.action}")
  end

  defp extract_agent_params(cmd) do
    team_id = cmd.payload["team_id"]
    agent_name = cmd.payload["agent_name"]

    if is_nil(team_id) or is_nil(agent_name) do
      CommandResponse.error(cmd.request_id, "team_id and agent_name required")
    else
      {:ok, team_id, agent_name}
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
