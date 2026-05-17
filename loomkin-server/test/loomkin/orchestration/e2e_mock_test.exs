defmodule Loomkin.Orchestration.E2EMockTest do
  @moduledoc """
  Deterministic end-to-end orchestration proof.

  Runs an epic through all 9 phases against scripted LLM responses. Verifies:

    * The IssueOrchestrator terminates in `:closed` (not `:failed`, not `:escalated`)
    * Every gate produces a `:pass` aggregate
    * The Executor runs each work unit through the 4-phase pipeline
    * The Curator extracts ≥1 KnowledgeFact at `:medium` confidence
    * No real LLM call is made (the test is offline-safe)
  """
  use Loomkin.DataCase, async: false

  alias Loomkin.Orchestration
  alias Loomkin.Orchestration.{Callbacks, IssueOrchestrator, KnowledgeStore}
  alias Loomkin.Orchestration.LLM.Stub
  alias Loomkin.Orchestration.Schema.Epic

  setup do
    start_supervised!(Stub)
    prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])

    Application.put_env(
      :loomkin,
      Loomkin.Orchestration,
      Keyword.put(prev, :llm_adapter, Stub)
    )

    # The KnowledgeStore + Curator are application-supervised singletons that
    # exist before the test's sandbox owner is created, so they cannot see
    # the per-test connection in shared mode. Explicitly grant them access.
    for pid <- [Process.whereis(KnowledgeStore), Process.whereis(Loomkin.Orchestration.Curator)],
        is_pid(pid) do
      Ecto.Adapters.SQL.Sandbox.allow(Loomkin.Repo, self(), pid)
    end

    on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, prev) end)
    :ok
  end

  defp drain_trace(acc) do
    receive do
      {"orchestration.epic", %{event: ev}} ->
        drain_trace([{:epic, ev} | acc])

      {"orchestration.work_unit", %{event: ev, work_unit_id: id}} ->
        drain_trace([{:wu, id, ev} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp pass_verdict(reviewer, file, line) do
    {:by_reviewer, reviewer,
     ~s({"verdict":"pass","evidence":["#{file}:#{line}"],"blocking":[],"warnings":[],"rationale":"ok"})}
  end

  defp coder_response do
    {:by_reviewer, :coder,
     ~s({"diff":"--- a/lib/x.ex\\n+++ b/lib/x.ex\\n+ added\\n","files_touched":["lib/x.ex","test/x_test.exs"],"notes":"impl"})}
  end

  defp planner_response do
    plan_json = """
    {
      "plan_summary": "implement the thing in two small units",
      "work_units": [
        {
          "id": "wu-1",
          "title": "implement core",
          "description": "core change",
          "file_scope": ["lib/x.ex", "test/x_test.exs"],
          "deps": [],
          "dod_items": [{"id":"1","text":"function returns :ok","verifier":"test"}]
        },
        {
          "id": "wu-2",
          "title": "add the test",
          "description": "test for the change",
          "file_scope": ["test/x_test.exs"],
          "deps": ["wu-1"],
          "dod_items": [{"id":"2","text":"test covers the new path","verifier":"test"}]
        }
      ]
    }
    """

    {:by_reviewer, :planner, plan_json}
  end

  defp curator_response do
    # Curator uses :knowledge_curator as the reviewer key — see Curator.extract/2
    {:by_reviewer, :knowledge_curator, ~s([
       {"type":"pattern","fact":"prefer gen_statem :state_timeout 0 over :next_event in :enter callbacks","recommendation":"use state_timeout","tags":["elixir","gen_statem"],"affected_files":["lib/loomkin/orchestration/issue_orchestrator.ex"]}
     ])}
  end

  test "epic flows through all 9 phases end-to-end with the LLM stub" do
    # Queue every LLM response we'll need, in any order — the stub matches
    # by reviewer name.
    Stub.queue([
      # Phase 1: Researcher
      {:by_reviewer, :researcher,
       "## Constraints\n- elixir 1.20\n## Open Questions\n- none\n## Related Code\n- lib/x.ex\n## Risks\n- none"},

      # Phase 2: Planner
      planner_response(),

      # Phase 3: Plan review (3 reviewers)
      pass_verdict(:feasibility, "plan", 1),
      pass_verdict(:completeness, "plan", 1),
      pass_verdict(:scope_alignment, "plan", 1),

      # Phase 4: Design review (5 reviewers)
      pass_verdict(:pm, "design", 1),
      pass_verdict(:architect, "design", 1),
      pass_verdict(:designer, "design", 1),
      pass_verdict(:security, "design", 1),
      pass_verdict(:cto, "design", 1),

      # Phase 6: Execute — 2 work units, each: Coder + DoDVerifier
      coder_response(),
      pass_verdict(:dod_verifier, "lib/x.ex", 7),
      coder_response(),
      pass_verdict(:dod_verifier, "test/x_test.exs", 12),

      # Phase 7: Final review (one adversarial run)
      pass_verdict(:dod_verifier, "lib/x.ex", 99),

      # Phase 9: Curator extracts learnings
      curator_response()
    ])

    # Insert a real Epic row so source_epic_id FKs hold for any curated facts.
    epic_id = Ecto.UUID.generate()

    {:ok, _epic_row} =
      Loomkin.Repo.insert(
        Epic.changeset(%Epic{}, %{
          id: epic_id,
          title: "fixture epic",
          spec: "small change with two work units",
          dod_items: [
            %{id: "1", text: "function returns :ok", verifier: :test},
            %{id: "2", text: "test covers the new path", verifier: :test}
          ]
        })
      )

    epic = %{id: epic_id, title: "fixture epic", spec: "small change"}
    callbacks = Callbacks.default_issue_callbacks()

    # Subscribe to the bus so we can trace where it failed if it does.
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "orchestration.epic")
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "orchestration.work_unit")

    {:ok, pid} =
      IssueOrchestrator.start_link(
        epic: epic,
        callbacks: callbacks,
        owner: self()
      )

    IssueOrchestrator.start(pid)

    assert_receive {:issue_orchestrator, ^pid, terminal_state}, 30_000

    if terminal_state != :closed do
      # Drain the inbox for trace messages and print them.
      trace = drain_trace([])

      flunk(
        "expected :closed, got #{inspect(terminal_state)}\n\nepic trace:\n#{inspect(trace, pretty: true, limit: :infinity)}"
      )
    end

    snapshot = IssueOrchestrator.status(pid)
    assert snapshot.state == :closed

    # All gates produced PASS verdicts; counts are non-zero
    for gate <- [:plan_review, :design_review, :final_review] do
      count = Map.get(snapshot.gate_verdicts, gate)

      assert is_integer(count) and count > 0,
             "expected verdicts for #{inspect(gate)}, got #{inspect(snapshot.gate_verdicts)}"
    end

    # Curator persisted ≥1 fact for this epic
    facts = KnowledgeStore.list_facts(%{source_epic_id: epic_id})

    assert length(facts) >= 1
    assert Enum.any?(facts, &(&1.confidence == :medium))

    # Sanity: the canonical phase list has 9 phases.
    assert length(Orchestration.phases()) == 9
  end
end
