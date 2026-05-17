defmodule Loomkin.Orchestration.CuratorAutoPromoteTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Orchestration.Curator
  alias Loomkin.Orchestration.KnowledgeStore
  alias Loomkin.Orchestration.LLM.Stub
  alias Loomkin.Orchestration.Schema.{Epic, KnowledgeFact}
  alias Loomkin.Repo

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

  describe "KnowledgeFact.signature/1" do
    test "is deterministic across struct instances" do
      f = %KnowledgeFact{type: :pattern, fact: "use state_timeout", tags: ["elixir", "otp"]}
      g = %KnowledgeFact{type: :pattern, fact: "use state_timeout", tags: ["elixir", "otp"]}
      assert KnowledgeFact.signature(f) == KnowledgeFact.signature(g)
    end

    test "is case- and whitespace-insensitive on fact text" do
      a = %KnowledgeFact{type: :pattern, fact: "Use State_Timeout", tags: ["elixir"]}
      b = %KnowledgeFact{type: :pattern, fact: "  use state_timeout  ", tags: ["elixir"]}
      c = %KnowledgeFact{type: :pattern, fact: "use\tstate_timeout", tags: ["elixir"]}
      assert KnowledgeFact.signature(a) == KnowledgeFact.signature(b)
      assert KnowledgeFact.signature(a) == KnowledgeFact.signature(c)
    end

    test "is insensitive to tag order and case" do
      a = %KnowledgeFact{type: :pattern, fact: "x", tags: ["B", "a"]}
      b = %KnowledgeFact{type: :pattern, fact: "x", tags: ["a", "b"]}
      assert KnowledgeFact.signature(a) == KnowledgeFact.signature(b)
    end

    test "differs when fact text differs" do
      a = %KnowledgeFact{type: :pattern, fact: "alpha", tags: []}
      b = %KnowledgeFact{type: :pattern, fact: "beta", tags: []}
      refute KnowledgeFact.signature(a) == KnowledgeFact.signature(b)
    end

    test "differs when tags differ" do
      a = %KnowledgeFact{type: :pattern, fact: "x", tags: ["a"]}
      b = %KnowledgeFact{type: :pattern, fact: "x", tags: ["a", "b"]}
      refute KnowledgeFact.signature(a) == KnowledgeFact.signature(b)
    end

    test "differs when type differs" do
      a = %KnowledgeFact{type: :pattern, fact: "x", tags: []}
      b = %KnowledgeFact{type: :gotcha, fact: "x", tags: []}
      refute KnowledgeFact.signature(a) == KnowledgeFact.signature(b)
    end
  end

  describe "KnowledgeStore.find_by_signature/2" do
    test "returns matches and respects :exclude_epic_id" do
      epic_a = insert_epic!()
      epic_b = insert_epic!()

      {:ok, fact_a} =
        KnowledgeStore.put_fact(%{
          id: Ecto.UUID.generate(),
          type: :pattern,
          fact: "shared insight",
          tags: ["elixir"],
          confidence: :medium,
          source_epic_id: epic_a
        })

      {:ok, fact_b} =
        KnowledgeStore.put_fact(%{
          id: Ecto.UUID.generate(),
          type: :pattern,
          fact: "shared insight",
          tags: ["elixir"],
          confidence: :medium,
          source_epic_id: epic_b
        })

      sig = KnowledgeFact.signature(fact_a)
      all = KnowledgeStore.find_by_signature(sig)
      assert Enum.sort(Enum.map(all, & &1.id)) == Enum.sort([fact_a.id, fact_b.id])

      only_b = KnowledgeStore.find_by_signature(sig, exclude_epic_id: epic_a)
      assert Enum.map(only_b, & &1.id) == [fact_b.id]
    end
  end

  describe "Curator auto-promotion" do
    test "promotes both new and prior fact to :high when same signature appears across distinct epics" do
      epic_a = insert_epic!()
      epic_b = insert_epic!()

      # First extraction for epic A
      Stub.queue([
        ~s([
          {"type":"pattern","fact":"prefer state_timeout 0 over :next_event in :enter callbacks",
           "recommendation":"use state_timeout","tags":["elixir","otp"],
           "affected_files":["lib/x.ex"]}
        ])
      ])

      summary_a = %{
        epic_id: epic_a,
        work_unit_id: Ecto.UUID.generate(),
        title: "wu a"
      }

      {:ok, [fact_a]} = Curator.extract(summary_a)
      assert fact_a.confidence == :medium

      # Second extraction for epic B — same fact text, same tags
      Stub.queue([
        ~s([
          {"type":"pattern","fact":"  Prefer State_Timeout 0 over :next_event in :enter callbacks ",
           "recommendation":"use state_timeout","tags":["OTP","elixir"],
           "affected_files":["lib/y.ex"]}
        ])
      ])

      summary_b = %{
        epic_id: epic_b,
        work_unit_id: Ecto.UUID.generate(),
        title: "wu b"
      }

      {:ok, [fact_b]} = Curator.extract(summary_b)

      # New fact returned at :high
      assert fact_b.confidence == :high

      # Prior fact has also been promoted in store
      reloaded_a = KnowledgeStore.get_fact(fact_a.id)
      assert reloaded_a.confidence == :high

      reloaded_b = KnowledgeStore.get_fact(fact_b.id)
      assert reloaded_b.confidence == :high
    end

    test "does not promote when both extractions come from the same epic" do
      epic = insert_epic!()

      Stub.queue([
        ~s([
          {"type":"pattern","fact":"only one epic saw this",
           "recommendation":"meh","tags":["t"],"affected_files":[]}
        ])
      ])

      summary = %{epic_id: epic, work_unit_id: Ecto.UUID.generate(), title: "wu 1"}
      {:ok, [fact_1]} = Curator.extract(summary)
      assert fact_1.confidence == :medium

      Stub.queue([
        ~s([
          {"type":"pattern","fact":"only one epic saw this",
           "recommendation":"meh","tags":["t"],"affected_files":[]}
        ])
      ])

      summary2 = %{epic_id: epic, work_unit_id: Ecto.UUID.generate(), title: "wu 2"}
      {:ok, [fact_2]} = Curator.extract(summary2)

      assert fact_2.confidence == :medium
      assert KnowledgeStore.get_fact(fact_1.id).confidence == :medium
      assert KnowledgeStore.get_fact(fact_2.id).confidence == :medium
    end
  end

  defp insert_epic! do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.insert(Epic.changeset(%Epic{}, %{id: id, title: "fixture", spec: "x"}))

    id
  end
end
