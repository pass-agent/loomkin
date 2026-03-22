defmodule Loomkin.Relay.Protocol.CommandResponse do
  @moduledoc """
  Sent by daemon to cloud as a response to a relayed command.

  The `request_id` correlates with the original `Command.request_id`.
  Status is "ok" for success, "error" for failure.
  """

  @type t :: %__MODULE__{
          request_id: String.t(),
          status: String.t(),
          data: map()
        }

  defstruct [:request_id, :status, data: %{}]

  def ok(request_id, data \\ %{}) do
    %__MODULE__{request_id: request_id, status: "ok", data: data}
  end

  def error(request_id, reason) when is_binary(reason) do
    %__MODULE__{request_id: request_id, status: "error", data: %{"error" => reason}}
  end

  def to_map(%__MODULE__{} = msg) do
    %{
      "type" => "command_response",
      "request_id" => msg.request_id,
      "status" => msg.status,
      "data" => msg.data
    }
  end

  def from_map(%{"type" => "command_response"} = map) do
    %__MODULE__{
      request_id: map["request_id"],
      status: map["status"],
      data: map["data"] || %{}
    }
  end
end
