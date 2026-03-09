---
phase: 10-leader-research-protocol
plan: "02"
subsystem: agent-genserver

tags: [exunit, tdd, genserver, research-protocol, registry, awaiting-synthesis]

# Dependency graph
requires:
  - phase: 10-leader-research-protocol
    plan: "00"
    provides: agent_research_protocol_test.exs stub file
  - phase: 09-spawn-safety
    provides: run_spawn_gate_intercept, execute_spawn_and_notify, Registry pattern
provides:
  - run_research_spawn/6 helper with budget check and collect_research_findings/3 loop
  - :awaiting_synthesis status with enter/exit cast handlers
  - pause guard clause for :awaiting_synthesis (queues, does not immediately pause)
  - peer_message routing via Registry to registered tool task pid
  - spawn_type optional schema param in TeamSpawn
affects: [10-03]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "research spawn bypasses human gate by matching spawn_type in [:research, 'research'] pre-check"
    - "tool task registers {:awaiting_synthesis, team_id, agent_name} in AgentRegistry before blocking"
    - "GenServer cast used for status transitions to avoid deadlock (tool task -> agent GenServer)"
    - "peer_message routing: head-matching clause for :awaiting_synthesis before general handler"

key-files:
  created: []
  modified:
    - lib/loomkin/teams/agent.ex
    - lib/loomkin/tools/team_spawn.ex
    - test/loomkin/teams/agent_research_protocol_test.exs

key-decisions:
  - "run_spawn_gate_intercept extracted to run_human_or_auto_spawn_gate/6 for the non-research path so research pre-check reads cleanly at the top"
  - "collect_research_findings/3 returns partial findings on timeout — leader proceeds with what arrived rather than erroring"
  - "execute_spawn_and_notify called with nil gate_id in research path — preserves existing pattern from auto_approve_spawns path"

patterns-established:
  - "pre-check spawn_type at top of intercept before any gate logic — research path short-circuits early"
  - "Registry key {:awaiting_synthesis, team_id, agent_name} mirrors {:spawn_gate, gate_id} pattern from Phase 9"

requirements-completed: [LEAD-01]

# Metrics
duration: 5min
completed: 2026-03-08
---

# Phase 10 Plan 02: Research Protocol Backend Mechanics Summary

**Research spawn auto-approve path, :awaiting_synthesis GenServer status, and Registry-based peer_message routing — 9 tests, 0 failures**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-09T03:05:35Z
- **Completed:** 2026-03-09T03:10:52Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Added optional `spawn_type` param to TeamSpawn Jido schema (`:atom`, not required, defaults absent)
- Refactored `run_spawn_gate_intercept/6` to pre-check `spawn_type` and route research spawns to `run_research_spawn/6`
- Implemented `run_research_spawn/6`: budget check, Registry registration, `{:enter_awaiting_synthesis, n}` cast, `execute_spawn_and_notify` with nil gate_id, blocking `collect_research_findings/3` receive loop, then `:exit_awaiting_synthesis` cast
- Added `collect_research_findings/3` tail-recursive receive loop with 120s timeout and partial-findings fallback
- Added `handle_cast({:enter_awaiting_synthesis, n}, state)` and `handle_cast(:exit_awaiting_synthesis, state)` status transition handlers
- Added `handle_cast(:request_pause, %{status: :awaiting_synthesis} = state)` guard clause that queues pause instead of immediately pausing
- Added head-matching `handle_cast({:peer_message, from, content}, %{status: :awaiting_synthesis, ...} = state)` clause before general peer_message handler — routes to registered tool task via Registry
- Replaced all 8 skipped stubs in `agent_research_protocol_test.exs` with 9 real tests that all pass

## Task Commits

Each task was committed atomically:

1. **Task 1 + Task 2: Full research protocol backend** - `5b94d93` (feat)

## Files Created/Modified

- `lib/loomkin/teams/agent.ex` — run_research_spawn/6, collect_research_findings/3, enter/exit_awaiting_synthesis casts, pause guard, peer_message routing clause, run_human_or_auto_spawn_gate/6 extraction
- `lib/loomkin/tools/team_spawn.ex` — spawn_type optional schema param added
- `test/loomkin/teams/agent_research_protocol_test.exs` — full implementation replacing all stubs; 9 tests, 0 failures, 0 skipped

## Decisions Made

- `run_spawn_gate_intercept/6` body extracted to `run_human_or_auto_spawn_gate/6` to keep the research pre-check readable at the top level — no behavioral change to existing path.
- `collect_research_findings/3` returns partial findings on timeout rather than erroring — leader proceeds with what arrived; this matches the plan's "partial findings on timeout" spec.
- Tasks 1 and 2 committed together since the peer_message routing implementation is deeply intertwined with the `run_research_spawn/6` function (both depend on the Registry key pattern).

## Deviations from Plan

### Auto-fixed Issues

None. Plan executed exactly as written with one minor structural note:

**Structural note (not a deviation):** Tasks 1 and 2 were committed in a single atomic commit because the implementation of both tasks is a unified change. The test file covers all behaviors from both tasks in one pass. This matches the TDD RED→GREEN flow where both task's behaviors were written as tests first, then implemented together.

## Issues Encountered

None. Pre-existing test failures (2 failures in `TeamTreeComponentTest` and `TaskGraphComponentTest` due to `:already_started` endpoint error) are unrelated to this plan and were confirmed to exist before these changes.

## User Setup Required

None.

## Next Phase Readiness

- All LEAD-01 backend behaviors implemented and tested
- `run_research_spawn/6` is ready for integration with the leader agent loop (Phase 10-03)
- Registry key `{:awaiting_synthesis, team_id, agent_name}` established for peer_message routing
- `agent_research_protocol_test.exs` green; `role_test.exs` unaffected (41 tests, 0 failures)

---
*Phase: 10-leader-research-protocol*
*Completed: 2026-03-08*

## Self-Check: PASSED

- FOUND: lib/loomkin/teams/agent.ex
- FOUND: lib/loomkin/tools/team_spawn.ex
- FOUND: test/loomkin/teams/agent_research_protocol_test.exs
- FOUND: .planning/phases/10-leader-research-protocol/10-02-SUMMARY.md
- FOUND commit: 5b94d93
