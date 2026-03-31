defmodule Loomkin.Relay.Protocol.Heartbeat do
  @moduledoc "Keep-alive sent by daemon at regular intervals."

  @type t :: %__MODULE__{timestamp: String.t()}

  defstruct [:timestamp]

  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "heartbeat",
      "timestamp" => msg.timestamp || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def from_map(%{"type" => "heartbeat"} = map) do
    %__MODULE__{timestamp: map["timestamp"]}
  end
end
