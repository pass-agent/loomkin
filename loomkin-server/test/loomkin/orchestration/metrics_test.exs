defmodule Loomkin.Orchestration.MetricsTest do
  use Loomkin.DataCase, async: true

  alias Ecto.UUID
  alias Loomkin.Orchestration.Metrics
  alias Loomkin.Orchestration.Schema.CostEvent
  alias Loomkin.Orchestration.Schema.PhaseMetric

  describe "record/1" do
    test "inserts a row with a generated id" do
      assert {:ok, %PhaseMetric{} = metric} =
               Metrics.record(%{
                 event_kind: :phase_entered,
                 phase: "plan_review",
                 epic_id: UUID.generate()
               })

      assert is_binary(metric.id)
      assert metric.event_kind == :phase_entered
      assert metric.iteration == 1
      assert metric.metadata == %{}
    end

    test "honors caller-provided id" do
      id = UUID.generate()

      assert {:ok, metric} =
               Metrics.record(%{
                 id: id,
                 event_kind: :gate_verdict,
                 gate: "plan_review",
                 verdict: :pass
               })

      assert metric.id == id
    end

    test "rejects unknown event_kind" do
      assert {:error, changeset} = Metrics.record(%{event_kind: :nope})
      refute changeset.valid?
      assert %{event_kind: _} = errors_on(changeset)
    end

    test "requires event_kind" do
      assert {:error, changeset} = Metrics.record(%{phase: "design"})
      assert %{event_kind: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list/1" do
    setup do
      epic_a = UUID.generate()
      epic_b = UUID.generate()
      old = DateTime.add(DateTime.utc_now(), -3600, :second)
      recent = DateTime.utc_now()

      {:ok, _} =
        insert_metric(%{
          epic_id: epic_a,
          event_kind: :phase_entered,
          phase: "plan",
          inserted_at: old
        })

      {:ok, _} =
        insert_metric(%{
          epic_id: epic_a,
          event_kind: :gate_verdict,
          gate: "plan_review",
          verdict: :pass,
          inserted_at: recent
        })

      {:ok, _} =
        insert_metric(%{
          epic_id: epic_b,
          event_kind: :gate_verdict,
          gate: "plan_review",
          verdict: :fail,
          inserted_at: recent
        })

      %{epic_a: epic_a, epic_b: epic_b, recent: recent}
    end

    test "returns every row when filters are empty" do
      assert length(Metrics.list()) == 3
    end

    test "filters by epic_id", %{epic_a: epic_a} do
      results = Metrics.list(%{epic_id: epic_a})
      assert length(results) == 2
      assert Enum.all?(results, &(&1.epic_id == epic_a))
    end

    test "filters by event_kind" do
      results = Metrics.list(%{event_kind: :gate_verdict})
      assert length(results) == 2
      assert Enum.all?(results, &(&1.event_kind == :gate_verdict))
    end

    test "filters by since", %{recent: recent} do
      cutoff = DateTime.add(recent, -60, :second)
      results = Metrics.list(%{since: cutoff})
      assert length(results) == 2
      assert Enum.all?(results, &(DateTime.compare(&1.inserted_at, cutoff) != :lt))
    end

    test "accepts string-keyed filter maps", %{epic_a: epic_a} do
      results = Metrics.list(%{"epic_id" => epic_a})
      assert length(results) == 2
    end
  end

  describe "aggregate/1" do
    setup do
      epic = UUID.generate()

      # plan_review gate: 2 pass, 1 fail across iterations 1,1,2
      {:ok, _} =
        insert_metric(%{
          epic_id: epic,
          event_kind: :gate_verdict,
          gate: "plan_review",
          verdict: :pass,
          iteration: 1,
          model: "anthropic:sonnet"
        })

      {:ok, _} =
        insert_metric(%{
          epic_id: epic,
          event_kind: :gate_verdict,
          gate: "plan_review",
          verdict: :pass,
          iteration: 1,
          model: "anthropic:sonnet"
        })

      {:ok, _} =
        insert_metric(%{
          epic_id: epic,
          event_kind: :gate_verdict,
          gate: "plan_review",
          verdict: :fail,
          iteration: 2,
          model: "openai:gpt"
        })

      # adversarial_review: 1 pass at iteration 3
      {:ok, _} =
        insert_metric(%{
          epic_id: epic,
          event_kind: :gate_verdict,
          gate: "adversarial_review",
          verdict: :pass,
          iteration: 3,
          model: "anthropic:sonnet"
        })

      # 2 escalations
      {:ok, _} = insert_metric(%{epic_id: epic, event_kind: :escalated})
      {:ok, _} = insert_metric(%{epic_id: epic, event_kind: :escalated})

      # non-gate noise that must NOT skew pass-rate
      {:ok, _} =
        insert_metric(%{
          epic_id: epic,
          event_kind: :phase_entered,
          phase: "implement"
        })

      %{epic: epic}
    end

    test "returns all six roll-up keys" do
      agg = Metrics.aggregate()

      assert Map.has_key?(agg, :pass_rate_by_gate)
      assert Map.has_key?(agg, :iteration_distribution)
      assert Map.has_key?(agg, :per_model_pass_rate)
      assert Map.has_key?(agg, :escalation_count)
      assert Map.has_key?(agg, :cost_per_epic)
      assert Map.has_key?(agg, :avg_phase_duration_ms_by_phase)
    end

    test "computes pass rate per gate" do
      %{pass_rate_by_gate: by_gate} = Metrics.aggregate()

      assert_in_delta by_gate["plan_review"], 2 / 3, 0.0001
      assert_in_delta by_gate["adversarial_review"], 1.0, 0.0001
    end

    test "computes iteration distribution across gate_verdict rows" do
      %{iteration_distribution: dist} = Metrics.aggregate()

      assert dist[1] == 2
      assert dist[2] == 1
      assert dist[3] == 1
      refute Map.has_key?(dist, nil)
    end

    test "computes per-model pass rate" do
      %{per_model_pass_rate: per_model} = Metrics.aggregate()

      assert_in_delta per_model["anthropic:sonnet"], 1.0, 0.0001
      assert_in_delta per_model["openai:gpt"], 0.0, 0.0001
    end

    test "counts escalations" do
      assert %{escalation_count: 2} = Metrics.aggregate()
    end

    test "respects epic_id filter", %{epic: epic} do
      other_epic = UUID.generate()
      {:ok, _} = insert_metric(%{epic_id: other_epic, event_kind: :escalated})

      assert %{escalation_count: 2} = Metrics.aggregate(%{epic_id: epic})
      assert %{escalation_count: 1} = Metrics.aggregate(%{epic_id: other_epic})
    end
  end

  describe "cost + eta aggregates" do
    setup do
      epic_a = UUID.generate()
      epic_b = UUID.generate()

      {:ok, _} = insert_cost(%{epic_id: epic_a, model: "sonnet", cost_usd: "1.23"})
      {:ok, _} = insert_cost(%{epic_id: epic_a, model: "sonnet", cost_usd: "0.77"})
      {:ok, _} = insert_cost(%{epic_id: epic_b, model: "haiku", cost_usd: "0.10"})
      # Unpriced row — should not break aggregation
      {:ok, _} = insert_cost(%{epic_id: epic_a, model: "unknown", cost_usd: nil})
      # Anonymous row — should be excluded from per-epic map
      {:ok, _} = insert_cost(%{epic_id: nil, model: "sonnet", cost_usd: "9.99"})

      # Phase durations for ETA
      {:ok, _} =
        insert_metric(%{
          epic_id: epic_a,
          event_kind: :phase_entered,
          phase: "plan",
          duration_ms: 5_000
        })

      {:ok, _} =
        insert_metric(%{
          epic_id: epic_a,
          event_kind: :phase_entered,
          phase: "decompose",
          duration_ms: 10_000
        })

      {:ok, _} =
        insert_metric(%{
          epic_id: epic_a,
          event_kind: :phase_entered,
          phase: "execute",
          duration_ms: 30_000
        })

      %{epic_a: epic_a, epic_b: epic_b}
    end

    test "cost_per_epic sums priced rows per epic", %{epic_a: a, epic_b: b} do
      %{cost_per_epic: by_epic} = Metrics.aggregate()

      assert Decimal.equal?(Decimal.round(by_epic[a], 2), Decimal.new("2.00"))
      assert Decimal.equal?(Decimal.round(by_epic[b], 2), Decimal.new("0.10"))
      # Rows with nil epic_id are not in the map
      refute Map.has_key?(by_epic, nil)
    end

    test "avg_phase_duration_ms_by_phase averages by phase string" do
      %{avg_phase_duration_ms_by_phase: by_phase} = Metrics.aggregate()

      assert by_phase["plan"] == 5_000
      assert by_phase["decompose"] == 10_000
      assert by_phase["execute"] == 30_000
    end

    test "cost_for_epic returns the per-epic sum", %{epic_a: a} do
      sum = Metrics.cost_for_epic(a)
      assert %Decimal{} = sum
      assert Decimal.equal?(Decimal.round(sum, 2), Decimal.new("2.00"))
    end

    test "eta_for_epic sums remaining phase averages from current phase", %{epic_a: a} do
      # current_phase = :plan_review → remaining phases = design_review,
      # decompose (10s), execute (30s), final_review, pr, closure.
      # decompose + execute average = 40_000 ms.
      assert Metrics.eta_for_epic(a, :plan_review) == 40_000
    end

    test "eta_for_epic returns nil when no remaining-phase data", %{epic_a: a} do
      assert Metrics.eta_for_epic(a, :closure) == nil
    end
  end

  defp insert_metric(attrs) do
    {inserted_at, attrs} = Map.pop(attrs, :inserted_at)
    attrs = Map.put_new(attrs, :id, UUID.generate())

    changeset = PhaseMetric.changeset(%PhaseMetric{}, attrs)

    changeset =
      if inserted_at do
        Ecto.Changeset.put_change(changeset, :inserted_at, inserted_at)
      else
        changeset
      end

    Loomkin.Repo.insert(changeset)
  end

  defp insert_cost(attrs) do
    attrs =
      attrs
      |> Map.put_new(:id, UUID.generate())
      |> Map.update(:cost_usd, nil, fn
        nil -> nil
        s when is_binary(s) -> Decimal.new(s)
        %Decimal{} = d -> d
      end)

    %CostEvent{}
    |> CostEvent.changeset(attrs)
    |> Loomkin.Repo.insert()
  end
end
