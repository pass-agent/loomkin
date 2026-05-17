# Loomkin Orchestration — Knowledge Base

The knowledge base is the long memory of every epic that ran through Loomkin. It is queried by `Primer.prime/2` at the start of every phase, and written by `Curator` at the end of every work unit.

## Fact schema

Ecto schema `Loomkin.Orchestration.Knowledge.Fact`:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `binary_id` | |
| `type` | `:pattern \| :gotcha \| :decision \| :anti_pattern \| :codebase_fact \| :api_behavior` | canonical knowledge fact types |
| `fact` | `string` | short description |
| `recommendation` | `string` | what to do |
| `confidence` | `:high \| :medium \| :low` | curator writes `:medium`; promotion needs human or repeat |
| `provenance` | `{:array, :map}` | list of `%{source: "human|agent|review", reference: "..."}` |
| `tags` | `{:array, :string}` | for primer search |
| `affected_files` | `{:array, :string}` | for primer search |
| `embedding` | `vector(384)` or `nil` | optional; used if `pgvector` is enabled |
| `inserted_at` | `utc_datetime_usec` | for recency ranking |

## JSONL compatibility

`Loomkin.Orchestration.Knowledge.Importer.import_jsonl/1` reads JSONL knowledge files. `Exporter.export_jsonl/1` writes them. Schema is bidirectional; the JSONL fields map 1:1.

Example fact (JSONL):

```json
{"id":"phoenix-liveview-1","type":"pattern","fact":"prefer LiveComponent for repeated UI shapes",
 "recommendation":"use LiveComponent when the same shape appears 2+ times","confidence":"high",
 "provenance":[{"source":"human","reference":"design review 2026-04-03"}],
 "tags":["phoenix","liveview","components"],"affectedFiles":["lib/loomkin_web/components/**"],
 "createdAt":"2026-04-03T10:00:00Z"}
```

## Priming

```elixir
Loomkin.Orchestration.Knowledge.Primer.prime(
  keywords: ["liveview", "components"],
  work_type: :planning,
  limit: 10
)
```

Ranking: `score = recency_decay × confidence_weight × tag_overlap`. Returns most relevant facts; the orchestrator includes them in the worker's system prompt.

## Curation

`Curator` GenServer subscribes to `orchestration.work_unit.completed`. For each completed unit it:

1. Reads the verdict trace + diff.
2. Asks an LLM to extract patterns/gotchas/decisions (one fact per finding, structured output).
3. Persists each fact at `confidence: :medium`.
4. Emits `orchestration.knowledge.fact_added` per fact.

Promotion to `:high` requires either a human flag or repeat detection (same fact extracted in 2+ epics with overlapping tags).

## LiveView browser

`/orchestration/knowledge` shows the fact list with filters: type, confidence, tag, affected file substring. Each fact links to the originating epic.
