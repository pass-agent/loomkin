defmodule Loomkin.Orchestration.MetricsTest do
  use Loomkin.DataCase, async: true

  alias Ecto.UUID
  alias Loomkin.Orchestration.Metrics
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

    test "returns all four roll-up keys" do
      agg = Metrics.aggregate()

      assert Map.has_key?(agg, :pass_rate_by_gate)
      assert Map.has_key?(agg, :iteration_distribution)
      assert Map.has_key?(agg, :per_model_pass_rate)
      assert Map.has_key?(agg, :escalation_count)
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
end
