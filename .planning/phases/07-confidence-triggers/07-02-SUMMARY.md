---
phase: 07-confidence-triggers
plan: "02"
subsystem: agent-genserver
tags: [elixir, genserver, ask-user, rate-limit, confidence-triggers, tdd]

# Dependency graph
requires:
  - phase: 07-confidence-triggers
    plan: "01"
    provides: failing test stubs for rate-limit guard behaviors
provides:
  - Rate-limit GenServer guard in Teams.Agent (last_asked_at, pending_ask_user fields)
  - handle_call({:check_ask_user_rate_limit, ...}) with :allow/:batch/:drop cond clauses
  - handle_call({:ask_user_answered, question_id}) for cooldown tracking
  - handle_cast({:append_ask_user_question, ...}) for batch card management
  - on_tool_execute rate-limit dispatch wired in build_loop_opts/1
affects:
  - 07-03 (WorkspaceLive ask-user card rendering and let_team_decide event)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "GenServer.call from tool task process reads live GenServer state for rate-limit decision"
    - "cond used instead of multi-clause guards when System.monotonic_time/1 needed"
    - "Ecto.UUID.generate() for card_id and question_id generation (consistent with AskUser tool)"
    - "Registry.register in handle_cast to allow answer routing to blocking tool task"

key-files:
  created: []
  modified:
    - lib/loomkin/teams/agent.ex
    - test/loomkin/teams/agent_confidence_test.exs

key-decisions:
  - "Used cond instead of multi-clause guards because System.monotonic_time/1 cannot be called in guards"
  - "on_tool_execute self() captures Agent GenServer pid at build_loop_opts call time (correct — not task pid)"
  - "ask_user_answered called with question_id from tool_args in :allow path; may be nil for legacy AskUser.run/2 which generates its own question_id internally"

patterns-established:
  - "Rate-limit guard pattern: GenServer.call from tool task before blocking tool execution"
  - "Batch append pattern: GenServer.cast to register question + publish signal + update state"

requirements-completed: [INTV-03]

# Metrics
duration: 6min
completed: 2026-03-08
---

# Phase 7 Plan 02: Confidence Triggers — Agent GenServer Rate-Limit Guard Summary

**GenServer-level ask_user rate-limit with :allow/:batch/:drop dispatch using last_asked_at and pending_ask_user state fields**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-08T20:02:25Z
- **Completed:** 2026-03-08T20:08:27Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added `last_asked_at` and `pending_ask_user` fields to `defstruct` in `Teams.Agent`
- Implemented `handle_call({:check_ask_user_rate_limit, tool_args})` with three outcomes via `cond`:
  - `:allow` — no open card, cooldown expired or never set; creates card, transitions to `:ask_user_pending`
  - `{:batch, card_id}` — card already open; returns existing card_id for appending
  - `:drop` — no open card but within 5-minute cooldown; returns without state change
- Implemented `handle_call({:ask_user_answered, question_id})` — removes question from card, clears card when empty, sets `last_asked_at`, transitions back to `:idle`
- Implemented `handle_cast({:append_ask_user_question, tool_args, card_id, question_id})` — registers question_id in Registry, publishes `AskUserQuestion` signal, appends question map to pending card
- Added `handle_cast(:request_pause, %{status: :ask_user_pending})` guard following the `approval_pending` pattern
- Wired rate-limit dispatch into `on_tool_execute` closure in `build_loop_opts/1` — all three paths handled
- Unskipped and implemented all 7 original stubs plus added 2 additional tests (9 total, all passing)

## Task Commits

Each task was committed atomically:

1. **Task 1: Add state fields and rate-limit handle_call to agent.ex** - `468bc00` (feat)
2. **Task 2: Wire rate-limit check into on_tool_execute closure** - `ab7ebd1` (feat)

## Files Created/Modified

- `lib/loomkin/teams/agent.ex` — two new defstruct fields, four new callback clauses, updated on_tool_execute closure
- `test/loomkin/teams/agent_confidence_test.exs` — 7 original stubs implemented + 2 new tests (9 total)

## Decisions Made

- Used `cond` instead of multi-clause function guards because `System.monotonic_time(:millisecond)` cannot be called inside Elixir guard expressions
- `self()` in `build_loop_opts/1` correctly captures the Agent GenServer pid (not the tool task pid) because `build_loop_opts/1` is called from within the GenServer process
- `Ecto.UUID.generate()` used for card_id and question_id generation, consistent with the existing `AskUser.run/2` pattern
- In the `:allow` path, `ask_user_answered` is called with the question_id from `tool_args` after `AskUser.run/2` returns; if no question_id is present (legacy path), the call is skipped to avoid nil key issues

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] System.monotonic_time/1 cannot be used in guards**
- **Found during:** Task 1 GREEN phase (compile error)
- **Issue:** Plan specified multi-clause `handle_call` guards using `System.monotonic_time(:millisecond)`, which is not allowed in Elixir guard expressions
- **Fix:** Merged into a single `handle_call` clause using `cond` for the three-way dispatch
- **Files modified:** `lib/loomkin/teams/agent.ex`
- **Commit:** `468bc00`

**2. [Rule 2 - Missing functionality] UUID.uuid4() not available; Ecto.UUID.generate() used instead**
- **Found during:** Task 1 implementation
- **Issue:** Plan referenced `UUID.uuid4()` but project uses `Ecto.UUID.generate()` (no elixir_uuid dependency)
- **Fix:** Used `Ecto.UUID.generate()` to match existing `AskUser.run/2` pattern
- **Files modified:** `lib/loomkin/teams/agent.ex`

## Issues Encountered

None beyond the two deviations auto-fixed above.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- `07-03` (WorkspaceLive ask-user card and `let_team_decide` event) can now rely on the GenServer rate-limit guard being fully implemented
- The `AskUserQuestion` signal is published by both the original `AskUser.run/2` (`:allow` path) and the new `append_ask_user_question` cast handler (`:batch` path) — WorkspaceLive will receive both via TeamBroadcaster
- No blockers

## Self-Check: PASSED

- SUMMARY.md: FOUND
- lib/loomkin/teams/agent.ex: FOUND
- Commit 468bc00: FOUND
- Commit ab7ebd1: FOUND

---
*Phase: 07-confidence-triggers*
*Completed: 2026-03-08*
