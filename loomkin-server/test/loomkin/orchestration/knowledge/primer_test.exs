defmodule Loomkin.Orchestration.Knowledge.PrimerTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Knowledge.Primer
  alias Loomkin.Orchestration.Schema.KnowledgeFact

  defp fact(id, opts) do
    now = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    %KnowledgeFact{
      id: id,
      type: Keyword.get(opts, :type, :pattern),
      fact: Keyword.get(opts, :fact, "fact #{id}"),
      confidence: Keyword.get(opts, :confidence, :medium),
      tags: Keyword.get(opts, :tags, []),
      affected_files: Keyword.get(opts, :affected_files, []),
      inserted_at: now
    }
  end

  test "ranks higher-confidence facts first when other inputs equal" do
    now = DateTime.utc_now()

    facts = [
      fact("low", confidence: :low, tags: ["liveview"], inserted_at: now),
      fact("medium", confidence: :medium, tags: ["liveview"], inserted_at: now),
      fact("high", confidence: :high, tags: ["liveview"], inserted_at: now)
    ]

    [first | _] = Primer.prime(facts: facts, keywords: ["liveview"], now: now)
    assert first.id == "high"
  end

  test "recency wins over slightly higher confidence when stale enough" do
    now = DateTime.utc_now()

    facts = [
      fact("ancient_high",
        confidence: :high,
        tags: ["x"],
        inserted_at: DateTime.add(now, -365 * 86_400, :second)
      ),
      fact("fresh_low", confidence: :low, tags: ["x"], inserted_at: now)
    ]

    [first | _] = Primer.prime(facts: facts, keywords: ["x"], now: now, limit: 2)
    assert first.id == "fresh_low"
  end

  test "tag overlap raises score" do
    now = DateTime.utc_now()

    facts = [
      fact("hit", tags: ["phoenix", "liveview"], inserted_at: now),
      fact("miss", tags: ["unrelated"], inserted_at: now)
    ]

    [first | _] = Primer.prime(facts: facts, keywords: ["phoenix"], now: now)
    assert first.id == "hit"
  end

  test "limit caps the returned list" do
    now = DateTime.utc_now()
    facts = for i <- 1..5, do: fact(Integer.to_string(i), tags: ["t"], inserted_at: now)

    assert length(Primer.prime(facts: facts, keywords: ["t"], limit: 2, now: now)) == 2
  end
end
