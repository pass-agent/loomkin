defmodule Loomkin.Signals do
  @moduledoc "Convenience helpers for publishing, subscribing, and replaying signals via the Bus."

  alias Jido.Signal.Bus

  @bus Loomkin.SignalBus

  @doc "Publish a single signal (or list) to the bus."
  def publish(%Jido.Signal{} = signal), do: Bus.publish(@bus, [signal])
  def publish(signals) when is_list(signals), do: Bus.publish(@bus, signals)

  @doc """
  Subscribe the calling process to signals matching `path`.

  The path uses glob-style matching (e.g. "agent.**", "team.dissolved").
  Note: `*` matches exactly one segment, `**` matches one or more segments.
  Signals are delivered as messages to the calling process.
  """
  def subscribe(path, opts \\ []) do
    pid = Keyword.get(opts, :pid, self())

    Bus.subscribe(@bus, path, dispatch: {:pid, target: pid, delivery_mode: :async})
  end

  @doc "Unsubscribe from the bus using a subscription ID returned by subscribe/2."
  def unsubscribe(subscription_id) do
    Bus.unsubscribe(@bus, subscription_id)
  end

  @doc "Replay recorded signals matching `path` from the bus log."
  def replay(path, start_timestamp \\ 0) do
    Bus.replay(@bus, path, start_timestamp)
  end

  @doc "Check whether a signal belongs to the given team (or has no team scope)."
  def signal_for_team?(%Jido.Signal{} = sig, team_id) do
    signal_team_id =
      get_in(sig.data, [:team_id]) ||
        get_in(sig, [Access.key(:extensions, %{}), "loomkin", "team_id"])

    signal_team_id == nil or signal_team_id == team_id
  end
end
