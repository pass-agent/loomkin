defmodule Loomkin.Orchestration.Personas do
  @moduledoc """
  Phase / gate / event → persona registry. Every orchestration signal is
  enriched with %{name, icon} so the CLI feed and LiveView dashboards can
  surface a named cast instead of anonymous atoms.
  """

  @type persona :: %{name: String.t(), icon: String.t(), role_blurb: String.t()}

  # By phase (the 9 IssueOrchestrator phases plus terminal states)
  @phase_personas %{
    research: %{
      name: "Researcher",
      icon: "🔬",
      role_blurb: "gathers context from your project"
    },
    plan: %{
      name: "Planner",
      icon: "📋",
      role_blurb: "drafts the work units"
    },
    plan_review: %{
      name: "Plan Council",
      icon: "⚖️",
      role_blurb: "feasibility · completeness · scope"
    },
    design_review: %{
      name: "Design Council",
      icon: "🏛",
      role_blurb: "PM · architect · designer · security · CTO"
    },
    decompose: %{
      name: "Decomposer",
      icon: "🧩",
      role_blurb: "splits the plan into work units"
    },
    execute: %{
      name: "Executor",
      icon: "🛠",
      role_blurb: "runs each work unit through the pipeline"
    },
    final_review: %{
      name: "Adversarial Reviewer",
      icon: "🔬",
      role_blurb: "DoD verification with file:line evidence"
    },
    pr: %{
      name: "PR Author",
      icon: "📤",
      role_blurb: "opens the pull request"
    },
    closure: %{
      name: "Curator",
      icon: "📚",
      role_blurb: "extracts learnings"
    },
    closed: %{
      name: "Curator",
      icon: "✅",
      role_blurb: "epic closed"
    },
    escalated: %{
      name: "Escalator",
      icon: "⚠️",
      role_blurb: "human attention requested"
    },
    failed: %{
      name: "System",
      icon: "❌",
      role_blurb: "epic failed"
    },
    pending: %{
      name: "System",
      icon: "⏳",
      role_blurb: "queued"
    }
  }

  # By work-unit pipeline state
  @work_unit_personas %{
    implement: %{
      name: "Coder",
      icon: "🛠",
      role_blurb: "writes the change"
    },
    validate: %{
      name: "Validator",
      icon: "🧪",
      role_blurb: "runs mix tasks against the worktree"
    },
    adversarial_review: %{
      name: "DoD Verifier",
      icon: "🔬",
      role_blurb: "cites file:line evidence per DoD item"
    },
    commit: %{
      name: "Committer",
      icon: "💾",
      role_blurb: "commits to the worktree branch"
    },
    done: %{
      name: "Committer",
      icon: "✅",
      role_blurb: "work unit committed"
    },
    failed: %{
      name: "System",
      icon: "❌",
      role_blurb: "work unit failed"
    }
  }

  # By gate name (when the subtype is :gate)
  @gate_personas %{
    plan_review: %{
      name: "Plan Council",
      icon: "⚖️",
      role_blurb: "feasibility · completeness · scope"
    },
    design_review: %{
      name: "Design Council",
      icon: "🏛",
      role_blurb: "PM · architect · designer · security · CTO"
    },
    adversarial_review: %{
      name: "Adversarial Reviewer",
      icon: "🔬",
      role_blurb: "DoD verification"
    }
  }

  # By knowledge event
  @knowledge_persona %{name: "Curator", icon: "📚", role_blurb: "extracts learnings"}

  @system_persona %{name: "System", icon: "•", role_blurb: ""}

  @doc """
  Resolves a persona for a SignalBridge payload.

  `subtype` is `:epic | :work_unit | :gate | :knowledge`.
  `payload.event` is a tuple like `{:phase_entered, :plan_review}` or
  `{:gate_verdict, :plan_review, :pass, 3}` or an atom like `:completed`
  / `:failed`.

  Always returns a persona map (falls back to @system_persona).
  """
  @spec for_event(atom(), map()) :: persona()
  def for_event(subtype, payload) when is_map(payload) do
    do_for_event(subtype, Map.get(payload, :event))
  end

  def for_event(_subtype, _payload), do: @system_persona

  # Knowledge subtype always uses the curator persona, regardless of event shape.
  defp do_for_event(:knowledge, _event), do: @knowledge_persona

  # Tuple events
  defp do_for_event(_subtype, {:phase_entered, phase}) when is_atom(phase) do
    for_phase(phase)
  end

  defp do_for_event(:gate, {:gate_verdict, gate, _verdict, _count}) when is_atom(gate) do
    for_gate(gate)
  end

  defp do_for_event(_subtype, {:gate_verdict, gate, _verdict, _count}) when is_atom(gate) do
    for_gate(gate)
  end

  defp do_for_event(_subtype, {:escalated, _reason}) do
    Map.fetch!(@phase_personas, :escalated)
  end

  defp do_for_event(:work_unit, {:retry, state, _reason}) when is_atom(state) do
    for_work_unit_state(state)
  end

  defp do_for_event(:work_unit, {:review_pass, _info}) do
    for_work_unit_state(:adversarial_review)
  end

  defp do_for_event(:work_unit, {:review_fail, _info}) do
    for_work_unit_state(:adversarial_review)
  end

  defp do_for_event(:work_unit, {:validate_fail, _info}) do
    for_work_unit_state(:validate)
  end

  defp do_for_event(:work_unit, {:commit_done, _sha}) do
    for_work_unit_state(:commit)
  end

  defp do_for_event(_subtype, {:fail, _where, _reason}) do
    @system_persona
  end

  # Atom events for epics / system
  defp do_for_event(:work_unit, :completed), do: for_work_unit_state(:done)
  defp do_for_event(:work_unit, :failed), do: for_work_unit_state(:failed)
  defp do_for_event(:work_unit, :validate_pass), do: for_work_unit_state(:validate)
  defp do_for_event(:work_unit, :started), do: for_work_unit_state(:implement)
  defp do_for_event(:work_unit, :implement_complete), do: for_work_unit_state(:implement)

  defp do_for_event(:epic, atom) when is_atom(atom) and not is_nil(atom) do
    case Map.get(@phase_personas, atom) do
      nil ->
        # Treat lifecycle atoms (:created, :started, :closed, :failed) as
        # system-ish unless explicitly mapped above.
        case atom do
          :closed -> Map.fetch!(@phase_personas, :closed)
          :failed -> Map.fetch!(@phase_personas, :failed)
          _ -> @system_persona
        end

      persona ->
        persona
    end
  end

  defp do_for_event(_subtype, _event), do: @system_persona

  @doc "Look up persona for a phase atom directly."
  @spec for_phase(atom()) :: persona()
  def for_phase(phase) when is_atom(phase) do
    Map.get(@phase_personas, phase, @system_persona)
  end

  @doc "Look up persona for a work-unit state atom."
  @spec for_work_unit_state(atom()) :: persona()
  def for_work_unit_state(state) when is_atom(state) do
    Map.get(@work_unit_personas, state, @system_persona)
  end

  @doc "Look up persona for a gate atom."
  @spec for_gate(atom()) :: persona()
  def for_gate(gate) when is_atom(gate) do
    Map.get(@gate_personas, gate, @system_persona)
  end

  @doc "Every defined persona, for the onboarding tour."
  @spec all() :: %{atom() => persona()}
  def all do
    Map.merge(@phase_personas, @work_unit_personas)
  end
end
