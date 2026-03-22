defmodule Loomkin.Relay.Client.EventForwarder do
  @moduledoc """
  Subscribes to the local Jido signal bus and forwards relevant events
  to the cloud relay via `Relay.Client.push_event/1`.

  Filters for signals that have a session_id or team_id (skips purely
  internal signals). Converts `Jido.Signal` structs to
  `Relay.Protocol.Event` structs for transport.
  """

  use GenServer

  require Logger

  alias Loomkin.Relay.Client
  alias Loomkin.Relay.Protocol.Event

  @signal_patterns [
    "agent.**",
    "session.**",
    "team.**"
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    subscription_ids =
      Enum.map(@signal_patterns, fn pattern ->
        case Loomkin.Signals.subscribe(pattern) do
          {:ok, id} -> id
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, %{subscription_ids: subscription_ids}}
  end

  @impl true
  def handle_info({:signal, %Jido.Signal{} = signal}, state) do
    forward_signal(signal)
    {:noreply, state}
  end

  def handle_info(%Jido.Signal{} = signal, state) do
    forward_signal(signal)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.subscription_ids, &Loomkin.Signals.unsubscribe/1)
    :ok
  end

  # --- Private ---

  defp forward_signal(%Jido.Signal{} = signal) do
    data = signal.data || %{}
    session_id = data[:session_id] || data["session_id"]
    team_id = data[:team_id] || data["team_id"]
    workspace_id = data[:workspace_id] || data["workspace_id"]

    if session_id || team_id do
      event = %Event{
        workspace_id: workspace_id,
        session_id: session_id,
        team_id: team_id,
        event_type: signal.type,
        data: serialize_data(data)
      }

      Client.push_event(event)
    end
  rescue
    e ->
      Logger.debug("[Relay:forwarder] failed to forward signal: #{inspect(e)}")
  end

  defp serialize_data(data) when is_map(data) do
    data
    |> Map.drop([:__struct__])
    |> Enum.into(%{}, fn
      {k, v} when is_atom(k) -> {to_string(k), serialize_value(v)}
      {k, v} -> {k, serialize_value(v)}
    end)
  end

  defp serialize_data(data), do: data

  defp serialize_value(v) when is_atom(v), do: to_string(v)
  defp serialize_value(v) when is_pid(v), do: inspect(v)
  defp serialize_value(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp serialize_value(%NaiveDateTime{} = v), do: NaiveDateTime.to_iso8601(v)
  defp serialize_value(v) when is_map(v), do: serialize_data(v)

  defp serialize_value(v) when is_list(v) do
    Enum.map(v, &serialize_value/1)
  end

  defp serialize_value(v), do: v
end
