# Loomkin Orchestration — End-to-End Verification

Two e2e paths: a deterministic mock that runs in CI, and a real-LLM smoke run gated behind an env var.

## Prerequisites

```bash
eval "$(mise activate bash)"
cd loomkin-server
mix deps.get
mix ecto.migrate
```

## Static + compile

```bash
eval "$(mise activate bash)" && cd loomkin-server && mix format --check-formatted
eval "$(mise activate bash)" && cd loomkin-server && mix compile --warnings-as-errors
```

## Precommit (lint, dialyzer, tests)

```bash
eval "$(mise activate bash)" && cd loomkin-server && mix precommit 2>&1 | tee /tmp/mix_precommit.log
```

## Mock E2E — runs offline, in CI

Runs the full 9-phase pipeline against a `req_llm` test adapter that scripts every reviewer/worker response. Asserts the epic ends in `:closed`, the gate trace matches the expected fixture, and the `Curator` extracted at least one knowledge fact.

```bash
eval "$(mise activate bash)" && cd loomkin-server \
  && mix test test/loomkin/orchestration/e2e_mock_test.exs 2>&1 | tee /tmp/mix_e2e_mock.log
```

## Real-LLM smoke run — manual, gated

Runs a real epic end-to-end against [`priv/orchestration/fixtures/sample_repo`](../../loomkin-server/priv/orchestration/fixtures/sample_repo/README.md) with the configured default `req_llm` provider. The fixture ships a deliberately broken `Greeter.greet/1` that ignores its argument; a successful orchestration run produces an Epic whose Coder restores the missing interpolation so `mix test` is green inside the worktree. Trace is captured at `docs/orchestration/E2E_TRACE.md` (this repo, not `loomkin-server/`).

Before running, set credentials for whichever provider is wired up via `:loomkin, Loomkin.Orchestration, :default_model`:

| Provider  | Env vars                                              |
| --------- | ----------------------------------------------------- |
| Anthropic | `ANTHROPIC_API_KEY`                                   |
| OpenAI    | `OPENAI_API_KEY` (optionally `OPENAI_ORG_ID`)         |
| Ollama    | `OLLAMA_HOST` (e.g. `http://localhost:11434`)         |
| Groq      | `GROQ_API_KEY`                                        |
| OpenRouter| `OPENROUTER_API_KEY`                                  |

Plus `LOOMKIN_ORCHESTRATION_LIVE_E2E=1` to acknowledge the spend.

```bash
LOOMKIN_ORCHESTRATION_LIVE_E2E=1 \
  ANTHROPIC_API_KEY=sk-ant-... \
  eval "$(mise activate bash)" && cd loomkin-server \
  && mix run priv/orchestration/run_live_e2e.exs 2>&1 | tee /tmp/orchestration_live_e2e.log
```

The runner does a 5s preflight LLM probe before creating the Epic and halts with exit code `3` if the provider is unreachable — no orchestration spend in that case. The resolved provider adapter + model are logged at the top of the trace so you know what produced it.

## LiveView click-through

```bash
eval "$(mise activate bash)" && cd loomkin-server && mix phx.server
```

1. Visit http://loom.test:4200/orchestration
2. Click "New Epic", paste a tiny spec with at least one DoD item, submit.
3. Watch the 9-phase progress bar advance.
4. Click into a work unit to see the 4-phase pipeline and reviewer verdicts.
5. Click a verdict's evidence row to see file:line.

## CLI smoke

```bash
pnpm -F cli build
pnpm -F cli exec loomkin orchestration status
```

Expected: a table of in-flight epics. Empty table is acceptable when the DB has none.

## Acceptance summary

The orchestration framework is "fully working e2e" when:

- `mix precommit` is green
- `mix test test/loomkin/orchestration/e2e_mock_test.exs` is green offline
- `LOOMKIN_ORCHESTRATION_LIVE_E2E=1` run completes against a real provider and writes a trace
- LiveView click-through reaches a verdict evidence table
- `pnpm -F cli build && pnpm -F cli exec loomkin orchestration status` renders without crash
