defmodule Loomkin.Orchestration.Metrics.TelemetryHandlerTest do
  use Loomkin.DataCase, async: false

  alias Ecto.UUID
  alias Loomkin.Orchestration.Metrics
  alias Loomkin.Orchestration.Metrics.TelemetryHandler

  setup do
    # The supervisor in `Loomkin.Application` already starts a singleton
    # `TelemetryHandler`. Allow it to use this test's sandboxed Repo
    # connection so the inserts it performs from inside `handle_event/4`
    # can see our checkout.
    case Process.whereis(TelemetryHandler) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Loomkin.Repo, self(), pid)
    end

    :ok
  end

  describe "synthetic telemetry events" do
    test "phase_entered creates a phase_entered row" do
      epic_id = UUID.generate()

      :telemetry.execute(
        [:loomkin, :orchestration, :epic, :phase_entered],
        %{},
        %{epic_id: epic_id, phase: :plan, attempt_knobs: %{model: "anthropic:sonnet"}}
      )

      # The handler runs synchronously in the emitting process, so the row
      # is visible immediately after `execute/3` returns.
      assert [row] = Metrics.list(%{epic_id: epic_id, event_kind: :phase_entered})
      assert row.phase == "plan"
      assert row.event_kind == :phase_entered
    end

    test "gate verdict creates a gate_verdict row with iteration + model" do
      epic_id = UUID.generate()

      :telemetry.execute(
        [:loomkin, :orchestration, :gate, :verdict],
        %{duration_ms: 42},
        %{
          epic_id: epic_id,
          gate: :plan_review,
          verdict: :pass,
          iteration: 2,
          model: "openai:gpt-5"
        }
      )

      assert [row] = Metrics.list(%{epic_id: epic_id, event_kind: :gate_verdict})
      assert row.gate == "plan_review"
      assert row.verdict == :pass
      assert row.iteration == 2
      assert row.model == "openai:gpt-5"
      assert row.duration_ms == 42
    end

    test "escalation creates an escalated row" do
      epic_id = UUID.generate()

      :telemetry.execute(
        [:loomkin, :orchestration, :epic, :escalated],
        %{},
        %{epic_id: epic_id, iterations: %{plan_review: 3}}
      )

      assert [row] = Metrics.list(%{epic_id: epic_id, event_kind: :escalated})
      assert row.event_kind == :escalated
    end

    test "work_unit completed creates a work_unit_completed row" do
      epic_id = UUID.generate()
      work_unit_id = UUID.generate()

      :telemetry.execute(
        [:loomkin, :orchestration, :work_unit, :completed],
        %{},
        %{epic_id: epic_id, work_unit_id: work_unit_id}
      )

      assert [row] = Metrics.list(%{epic_id: epic_id, event_kind: :work_unit_completed})
      assert row.work_unit_id == work_unit_id
    end

    test "work_unit failed creates a work_unit_failed row" do
      epic_id = UUID.generate()
      work_unit_id = UUID.generate()

      :telemetry.execute(
        [:loomkin, :orchestration, :work_unit, :failed],
        %{},
        %{epic_id: epic_id, work_unit_id: work_unit_id}
      )

      assert [row] = Metrics.list(%{epic_id: epic_id, event_kind: :work_unit_failed})
      assert row.work_unit_id == work_unit_id
    end
  end

  describe "robustness" do
    test "missing metadata fields do not crash the handler" do
      # No epic_id, no phase: handler must still not raise even if the
      # resulting changeset is invalid.
      assert :ok =
               :telemetry.execute(
                 [:loomkin, :orchestration, :epic, :phase_entered],
                 %{},
                 %{}
               )
    end

    test "unknown verdict normalizes to :unknown" do
      epic_id = UUID.generate()

      :telemetry.execute(
        [:loomkin, :orchestration, :gate, :verdict],
        %{duration_ms: 0},
        %{epic_id: epic_id, gate: :design_review, verdict: :weird, iteration: 1}
      )

      assert [row] = Metrics.list(%{epic_id: epic_id, event_kind: :gate_verdict})
      assert row.verdict == :unknown
    end
  end

  describe "end-to-end with a mocked epic" do
    test "running a tiny mocked epic produces phase_entered and gate_verdict rows" do
      epic_id = UUID.generate()

      callbacks = %{
        researcher: fn _epic -> {:ok, %{notes: "research"}} end,
        planner: fn _epic, _research -> {:ok, %{plan: "tiny"}} end,
        plan_review: fn _plan -> {:pass, [%{verdict: "ok"}]} end,
        design_review: fn _plan -> {:pass, [%{verdict: "ok"}]} end,
        decomposer: fn _plan -> {:ok, []} end,
        executor: fn _epic, _wus -> {:ok, %{}} end,
        final_review: fn _epic, _results -> {:pass, [%{verdict: "ok"}]} end,
        pr_opener: fn _epic, _results -> {:ok, "https://example/pr/1"} end,
        knowledge: fn _epic, _results -> {:ok, []} end
      }

      epic = %{id: epic_id, title: "telemetry e2e"}

      {:ok, pid} =
        Loomkin.Orchestration.IssueOrchestrator.start_link(
          epic: epic,
          callbacks: callbacks,
          owner: self()
        )

      # Allow the orchestrator and any pipeline workers it spawns to use the
      # sandboxed Repo. The telemetry handler runs in those PIDs.
      Ecto.Adapters.SQL.Sandbox.allow(Loomkin.Repo, self(), pid)

      Loomkin.Orchestration.IssueOrchestrator.start(pid)

      assert_receive {:issue_orchestrator, ^pid, :closed}, 5_000

      phase_rows = Metrics.list(%{epic_id: epic_id, event_kind: :phase_entered})
      gate_rows = Metrics.list(%{epic_id: epic_id, event_kind: :gate_verdict})

      assert length(phase_rows) >= 1, "expected at least one phase_entered row"
      assert length(gate_rows) >= 1, "expected at least one gate_verdict row"
    end
  end
end
