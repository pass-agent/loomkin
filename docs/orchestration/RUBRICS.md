# Loomkin Orchestration — Rubrics

Every gate is a list of reviewers. Every reviewer implements `Loomkin.Orchestration.Reviewer`. Verdicts are binary: `:pass | :fail`, with mandatory evidence.

## Reviewer contract

```elixir
@callback name() :: atom()
@callback rubric() :: String.t()
@callback model() :: String.t() | nil
@callback review(payload :: map()) ::
  {:ok, %Loomkin.Orchestration.Schema.ReviewVerdict{}} | {:error, term()}
```

The verdict must include:

- `verdict` — `:pass` or `:fail`
- `reviewer` — module name
- `evidence` — list of strings, each matching `~r/^[^:\s]+:\d+/` (file:line)
- `blocking` — list of blocking issues (empty if `:pass`)
- `warnings` — list of non-blocking issues
- `rationale` — short prose explanation

`AdversarialReviewGate` rejects any verdict whose `evidence` list is empty.

## Gate roster

### `PlanReviewGate` — 3 reviewers

| Reviewer | Rubric focus |
| --- | --- |
| `Feasibility` | Technical viability, dependency risk, time/resource fit |
| `Completeness` | DoD coverage, missing work units, edge cases |
| `ScopeAlignment` | Stays in issue scope, follows codebase conventions |

**Pass criteria**: all 3 reviewers return `:pass`.

### `DesignReviewGate` — 5 reviewers

| Reviewer | Rubric focus |
| --- | --- |
| `PM` | Solves the user problem, scope correctness |
| `Architect` | Service shape, coupling, scalability |
| `Designer` | UX, accessibility, copy, affordances |
| `Security` | OWASP top 10, auth, data handling |
| `CTO` | Strategic alignment, build/buy, debt |

**Pass criteria**: all 5 reviewers return `:pass`. Up to 3 iterations; iteration 4 escalates.

### `AdversarialReviewGate` — DoD verifier (per work unit)

One reviewer (`DoDVerifier`) iterates each DoD item and emits one verdict per item.

| Verdict | Meaning |
| --- | --- |
| `:pass` | DoD item demonstrably met; `file:line` evidence cited for impl + test |
| `:fail` | Not met; reviewer must cite the missing or incorrect `file:line` |

**Pass criteria**: all DoD verdicts are `:pass` AND every verdict has `file:line` evidence.

## Rubric snippets (used as system prompts)

These live as data in `loomkin-server/priv/orchestration/rubrics/*.md` and are loaded at boot. They mirror the project's rubric patterns expressed in Elixir/Phoenix vocabulary.

## Iteration cap

Each gate is capped at 3 iterations. On the 4th attempt the orchestrator emits `orchestration.epic.escalated` and parks the epic in `awaiting_human` until a human posts `bd remember` or clicks "Resume" in LiveView.
