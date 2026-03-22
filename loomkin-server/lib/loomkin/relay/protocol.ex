defmodule Loomkin.Relay.Protocol do
  @moduledoc """
  Message types for the relay protocol between local daemons and the cloud relay.

  All messages are JSON-encoded maps with a `type` field for routing.
  Use `encode/1` and `decode/1` for serialization.
  """

  alias Loomkin.Relay.Protocol.Command
  alias Loomkin.Relay.Protocol.CommandResponse
  alias Loomkin.Relay.Protocol.Event
  alias Loomkin.Relay.Protocol.Heartbeat
  alias Loomkin.Relay.Protocol.HeartbeatAck
  alias Loomkin.Relay.Protocol.Register
  alias Loomkin.Relay.Protocol.WorkspaceUpdate

  @type message ::
          Register.t()
          | Heartbeat.t()
          | HeartbeatAck.t()
          | Command.t()
          | CommandResponse.t()
          | Event.t()
          | WorkspaceUpdate.t()

  @doc "Encode a protocol struct to a JSON binary."
  @spec encode(message()) :: {:ok, binary()} | {:error, term()}
  def encode(%{__struct__: module} = msg) do
    msg
    |> module.to_map()
    |> Jason.encode()
  end

  @doc "Decode a JSON binary into the appropriate protocol struct."
  @spec decode(binary()) :: {:ok, message()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      decode_map(map)
    end
  end

  @doc "Decode a pre-parsed map into the appropriate protocol struct."
  @spec decode_map(map()) :: {:ok, message()} | {:error, :unknown_type}
  def decode_map(%{"type" => "register"} = map), do: {:ok, Register.from_map(map)}
  def decode_map(%{"type" => "heartbeat"} = map), do: {:ok, Heartbeat.from_map(map)}
  def decode_map(%{"type" => "heartbeat_ack"} = map), do: {:ok, HeartbeatAck.from_map(map)}
  def decode_map(%{"type" => "command"} = map), do: {:ok, Command.from_map(map)}
  def decode_map(%{"type" => "command_response"} = map), do: {:ok, CommandResponse.from_map(map)}
  def decode_map(%{"type" => "event"} = map), do: {:ok, Event.from_map(map)}
  def decode_map(%{"type" => "workspace_update"} = map), do: {:ok, WorkspaceUpdate.from_map(map)}
  def decode_map(_), do: {:error, :unknown_type}

  # --- Command action constants ---

  @actions ~w(
    send_message cancel get_history get_status
    approve_tool deny_tool
    get_agents pause_agent resume_agent steer_agent
    change_model kill_team
  )

  @doc "List of valid command action strings."
  def valid_actions, do: @actions
end
