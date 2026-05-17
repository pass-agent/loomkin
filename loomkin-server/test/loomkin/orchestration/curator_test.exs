defmodule Loomkin.Orchestration.CuratorTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Orchestration.Curator
  alias Loomkin.Orchestration.KnowledgeStore
  alias Loomkin.Orchestration.LLM.Stub

  setup do
    start_supervised!(Stub)
    prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])

    Application.put_env(
      :loomkin,
      Loomkin.Orchestration,
      Keyword.put(prev, :llm_adapter, Stub)
    )

    on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, prev) end)
    :ok
  end

  test "extracts ≥1 fact from a work-unit summary and persists at :medium confidence" do
    Stub.queue([
      ~s([
        {"type":"pattern","fact":"prefer state_timeout 0 over :next_event in :enter callbacks",
         "recommendation":"use state_timeout","tags":["elixir","gen_statem"],
         "affected_files":["lib/loomkin/orchestration/issue_orchestrator.ex"]}
      ])
    ])

    # The fact references source_epic_id (FK); insert an Epic so the FK holds.
    epic_id = Ecto.UUID.generate()

    {:ok, _} =
      Loomkin.Repo.insert(
        Loomkin.Orchestration.Schema.Epic.changeset(
          %Loomkin.Orchestration.Schema.Epic{},
          %{id: epic_id, title: "fixture epic", spec: "x"}
        )
      )

    summary = %{
      epic_id: epic_id,
      work_unit_id: Ecto.UUID.generate(),
      title: "wire state machine",
      verdict: :pass,
      diff_summary: "added :state_timeout, 0 actions in enter callbacks"
    }

    {:ok, [fact]} = Curator.extract(summary)

    assert fact.type == :pattern
    assert fact.confidence == :medium
    assert "elixir" in fact.tags
    assert fact.source_epic_id == summary.epic_id
    assert hd(fact.provenance)["source"] == "agent"

    # Persisted in the store
    loaded = KnowledgeStore.get_fact(fact.id)
    assert loaded.id == fact.id
  end

  test "empty extraction returns empty list (no facts to learn)" do
    Stub.queue(["[]"])

    {:ok, []} = Curator.extract(%{work_unit_id: "x"})
  end
end
