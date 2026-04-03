defmodule Loomkin.Signals.Extensions.Causality do
  @moduledoc """
  Causality tracking extension for Loomkin signals.

  Adds Loomkin-specific context fields to any signal so that causal chains
  can be traced across agent interactions, task lifecycles, and team events.

  ## Fields

  - `team_id` — the team this signal originated from
  - `agent_name` — the agent that emitted the signal
  - `trigger_signal_id` — the signal ID that caused this signal (causal parent)
  - `task_id` — the task context, if any

  ## Usage

  Attach causality metadata to a signal after creation:

      signal = Loomkin.Signals.Agent.Status.new!(%{...})
      signal = Causality.attach(signal, team_id: "t1", agent_name: "coder")

  Or with a trigger signal for full chain tracing:

      signal = Causality.attach(signal,
        team_id: "t1",
        agent_name: "coder",
        trigger_signal_id: parent_signal.id
      )
  """

  use Jido.Signal.Ext,
    namespace: "loomkin",
    schema: [
      team_id: [type: :string, doc: "Team that originated this signal"],
      agent_name: [type: :string, doc: "Agent that emitted this signal"],
      trigger_signal_id: [type: :string, doc: "ID of the signal that caused this one"],
      task_id: [type: :string, doc: "Task context for this signal"]
    ]

  @doc """
  Attach causality metadata to an existing signal.

  Merges the provided fields into the signal's `extensions` map under
  the `"loomkin"` namespace key.

  ## Options

  - `:team_id` — team identifier
  - `:agent_name` — agent name
  - `:trigger_signal_id` — ID of the causal parent signal
  - `:task_id` — task identifier

  All fields are optional; only non-nil values are included.
  """
  @spec attach(Jido.Signal.t(), keyword()) :: Jido.Signal.t()
  def attach(%Jido.Signal{} = signal, opts \\ []) do
    causality_data =
      %{}
      |> maybe_put(:team_id, Keyword.get(opts, :team_id))
      |> maybe_put(:agent_name, Keyword.get(opts, :agent_name))
      |> maybe_put(:trigger_signal_id, Keyword.get(opts, :trigger_signal_id))
      |> maybe_put(:task_id, Keyword.get(opts, :task_id))

    extensions = Map.get(signal, :extensions, %{})
    updated_extensions = Map.put(extensions, "loomkin", causality_data)
    %{signal | extensions: updated_extensions}
  end

  @doc """
  Extract causality metadata from a signal's extensions.

  Returns a map with the causality fields, or an empty map if none present.
  """
  @spec extract(Jido.Signal.t()) :: map()
  def extract(%Jido.Signal{} = signal) do
    signal
    |> Map.get(:extensions, %{})
    |> Map.get("loomkin", %{})
  end

  @doc """
  Returns the trigger signal ID from a signal's causality metadata, or nil.
  """
  @spec trigger_id(Jido.Signal.t()) :: String.t() | nil
  def trigger_id(%Jido.Signal{} = signal) do
    extract(signal) |> Map.get(:trigger_signal_id)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))
end
