defmodule Loomkin.Channels.Severity do
  @moduledoc """
  Classifies Signal events into severity levels for channel notification filtering.

  Severity levels:
  - `:urgent` — requires immediate attention (ask_user, errors, team dissolved, permission requests)
  - `:action` — actionable updates (agent messages, task completions, conflicts, consensus)
  - `:info` — informational (context updates, other collab events, status changes)
  - `:noise` — always suppressed (stream deltas, tool executing, usage telemetry)
  """

  @type severity :: :urgent | :action | :info | :noise

  @doc "Classify a signal or event into a severity level."
  @spec classify(term()) :: severity()

  # Urgent signals
  def classify(%Jido.Signal{type: "team.ask_user.question"}), do: :urgent
  def classify(%Jido.Signal{type: "agent.error"}), do: :urgent
  def classify(%Jido.Signal{type: "team.dissolved"}), do: :urgent
  def classify(%Jido.Signal{type: "team.permission.request"}), do: :urgent
  def classify(%Jido.Signal{type: "session.permission.request"}), do: :urgent
  def classify(%Jido.Signal{type: "session.cancelled"}), do: :urgent
  def classify(%Jido.Signal{type: "session.llm.error"}), do: :urgent
  def classify(%Jido.Signal{type: "team.budget.warning"}), do: :urgent

  # Action signals
  def classify(%Jido.Signal{type: "session.message.new"}), do: :action
  def classify(%Jido.Signal{type: "team.conflict.detected"}), do: :action
  def classify(%Jido.Signal{type: "agent.escalation"}), do: :action

  # Info signals
  def classify(%Jido.Signal{type: "collaboration." <> _}), do: :info
  def classify(%Jido.Signal{type: "context." <> _}), do: :info
  def classify(%Jido.Signal{type: "channel." <> _}), do: :info
  def classify(%Jido.Signal{type: "session.status.changed"}), do: :info
  def classify(%Jido.Signal{type: "session.team.available"}), do: :info
  def classify(%Jido.Signal{type: "session.child_team.available"}), do: :info
  def classify(%Jido.Signal{type: "team.llm.stop"}), do: :info

  # Noise signals
  def classify(%Jido.Signal{type: "agent.stream." <> _}), do: :noise
  def classify(%Jido.Signal{type: "agent.tool.executing"}), do: :noise
  def classify(%Jido.Signal{type: "agent.usage"}), do: :noise

  def classify(_), do: :info

  @doc "Check if a severity level is included in the notify config."
  @spec notify?(severity(), [String.t()] | [atom()]) :: boolean()
  def notify?(:noise, _levels), do: false

  def notify?(severity, levels) do
    severity_str = to_string(severity)
    Enum.any?(levels, fn level -> to_string(level) == severity_str end)
  end

  @doc "Default severity levels to forward."
  @spec default_levels() :: [String.t()]
  def default_levels, do: ["urgent", "action"]
end
