# Loomkin Orchestration — Intent Classifier

Every user message that enters `Loomkin.Session.handle_call({:send_message, …})` is classified before it dispatches. The classifier decides which pipeline runs:

| Intent           | Pipeline       | Phases                                                                |
| ---------------- | -------------- | --------------------------------------------------------------------- |
| `:fast_chat`     | LitePipeline   | 1 phase — spawn/reuse a `Loomkin.Teams.Agent`; no gates               |
| `:tool_use`      | ShortPipeline  | 3 phases — implement → validate → commit (no review gates)            |
| `:complex_task`  | Full pipeline  | 9 phases — research → plan → plan_review → design_review → decompose → execute → final_review → pr → closure |
| `:ambiguous`     | LLM fallback   | classifier asks a small fast model, then maps to one of the above     |

## Why hybrid

A pure-LLM classifier would add ~200ms + a per-message API spend to *every* chat — including "ok" or "thanks". A pure-rule classifier misses nuance. The hybrid runs the rules first, falls back to the LLM only when the rules can't decide. Target: ≥90% of messages resolved by rules alone.

## Rule set (in evaluation order)

`Loomkin.Orchestration.IntentRules.classify/2` evaluates these in order. The first match wins.

| # | Rule                                                          | Verdict          | Examples                                         |
| - | ------------------------------------------------------------- | ---------------- | ------------------------------------------------ |
| 1 | Empty or whitespace-only message                              | `:fast_chat`     | `""`, `"\n\n"`                                   |
| 2 | Length ≤ 3 chars                                              | `:fast_chat`     | `"hi"`, `"ok"`, `"no"`                           |
| 3 | Greeting / acknowledgement                                    | `:fast_chat`     | `"hello"`, `"thanks"`, `"sounds good"`           |
| 4 | Question with no code-fence and no file path mentioned, ≤ 280 chars | `:fast_chat`     | `"what does Loomkin do?"`                        |
| 5 | Contains code fence (```) with diff/patch markers (`@@`, `+++`) | `:complex_task` | a posted diff                                    |
| 6 | Contains action verb + file path                              | `:complex_task`  | `"refactor lib/x.ex to use gen_statem"`          |
| 7 | Contains action verb without file scope, ≤ 200 chars          | `:tool_use`      | `"run the tests"`, `"show me git status"`        |
| 8 | Multi-paragraph (≥ 2 blank lines) AND contains spec keywords (`DoD`, `acceptance`, `requirement`) | `:complex_task` | a real spec dump |
| 9 | Anything else                                                 | `:ambiguous`     | falls through to the LLM fallback                |

### Action verbs (rule 6 / 7)

`implement`, `add`, `build`, `create`, `refactor`, `fix`, `repair`, `debug`, `test`, `migrate`, `port`, `wire`, `extract`, `inline`, `rename`, `delete`, `remove`, `replace`, `simplify`, `optimize`, `parallelize`, `document`, `audit`, `review`, `lint`, `format`

### Greeting set (rule 3)

Case-insensitive match against:
`hi`, `hello`, `hey`, `yo`, `sup`, `morning`, `evening`, `thanks`, `thank you`, `ty`, `sounds good`, `ok`, `okay`, `cool`, `nice`, `got it`, `understood`, `sure`, `yes`, `no`, `nope`, `yeah`, `nah`

## LLM fallback contract

When `IntentRules.classify/2` returns `:ambiguous`, `IntentClassifier.classify/2` calls `Loomkin.Orchestration.LLM.complete/2` with:

- A short system prompt asking for strict JSON: `{"intent": "fast_chat|tool_use|complex_task", "confidence": "high|medium|low", "rationale": "..."}`
- The full user message
- A small model (configured via `:loomkin, Loomkin.Orchestration, fast_model:` — defaults to the configured default fast model)
- Timeout 2_000 ms; on timeout/error, defaults to `:complex_task` (fail-safe toward more rigour, not less)

## Why fail safe to `:complex_task`

A misclassified `:fast_chat` may give an unhelpful answer. A misclassified `:complex_task` "only" runs the user's intent through more review. The asymmetry favours fail-safe-to-more-rigour.

## Telemetry

Every classification emits a `:telemetry` event under `[:loomkin, :orchestration, :intent, :classified]` with:

- `:intent` — the chosen intent
- `:via` — `:rule_<n>` or `:llm`
- `:duration_ms`

The LiveView orchestration dashboard surfaces a rolling rule-coverage % so we can see when the rule set drifts away from real traffic.
