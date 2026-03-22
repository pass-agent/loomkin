defmodule Loomkin.Relay.Protocol.HeartbeatAck do
  @moduledoc "Sent by cloud to confirm heartbeat received."

  @type t :: %__MODULE__{timestamp: String.t()}

  defstruct [:timestamp]

  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "heartbeat_ack",
      "timestamp" => msg.timestamp || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def from_map(%{"type" => "heartbeat_ack"} = map) do
    %__MODULE__{timestamp: map["timestamp"]}
  end
end
