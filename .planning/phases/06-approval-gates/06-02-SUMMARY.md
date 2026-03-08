---
phase: 06-approval-gates
plan: "02"
subsystem: api
tags: [jido, signals, approval-gates, registry, team-broadcaster]

# Dependency graph
requires:
  - phase: 06-01
    provides: failing test stubs for RequestApproval tool and approval signal classification
  - phase: 05-chat-injection-state-machines
    provides: TeamBroadcaster critical_types pattern and AgentRegistry routing pattern

provides:
  - Loomkin.Signals.Approval.Requested signal struct (type agent.approval.requested)
  - Loomkin.Signals.Approval.Resolved signal struct (type agent.approval.resolved)
  - Loomkin.Tools.RequestApproval jido action that blocks tool task until human responds
  - approval signal types in TeamBroadcaster @critical_types for immediate LiveView delivery
  - RequestApproval in @peer_tools and :gate_id/:gate_context in @known_param_keys in registry
  - config :loomkin, :approval_gate_timeout_ms, 300_000 for 5-minute default timeout

affects:
  - 06-03 (workspace_live approval handling — routes :approval_response to tool task via registry)
  - 06-04 (agent card ui — renders ApprovalRequested signal and sends approve/deny events)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - blocking-tool-task pattern: tool task registers in AgentRegistry under {:approval_gate, gate_id}, blocks in receive, response routed via send/2 — mirrors AskUser pattern exactly
    - approval signal pair: Requested published when gate opens, Resolved published on all three outcomes (approved/denied/timeout)
    - runtime config: Application.get_env/3 at call time (not compile time) so test config overrides work

key-files:
  created:
    - lib/loomkin/signals/approval.ex
    - lib/loomkin/tools/request_approval.ex
  modified:
    - lib/loomkin/teams/team_broadcaster.ex
    - lib/loomkin/tools/registry.ex
    - config/config.exs
    - test/loomkin/tools/request_approval_test.exs

key-decisions:
  - "approval gate tool blocks only the tool task process, not the agent GenServer — agent keeps running"
  - "timeout param in seconds (not ms) at invocation level; app config approval_gate_timeout_ms in ms at system level"
  - "Resolved signal published on all three outcomes so LiveView always receives close notification"
  - "RequestApproval in @peer_tools (not @lead_tools) — any team agent may request approval, not only leads"

patterns-established:
  - "blocking-gate pattern: register under {:approval_gate, gate_id}, publish Requested, receive response, unregister, publish Resolved"

requirements-completed:
  - INTV-02

# Metrics
duration: 7min
completed: 2026-03-08
---

# Phase 06 Plan 02: Approval Gate Backend Summary

**RequestApproval jido action with configurable timeout, Approval.Requested/Resolved signals, and critical classification in TeamBroadcaster — full server-side approval gate contract established**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-03-08T18:40:30Z
- **Completed:** 2026-03-08T18:47:19Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments

- Implemented `Loomkin.Tools.RequestApproval` following the AskUser blocking pattern — tool task registers in AgentRegistry under `{:approval_gate, gate_id}`, publishes Approval.Requested, blocks in `receive`, routes approved/denied/timeout into typed result maps
- Created `Loomkin.Signals.Approval.Requested` and `Loomkin.Signals.Approval.Resolved` signal structs with type strings `agent.approval.requested` and `agent.approval.resolved`
- Added both approval signal types to `@critical_types` in TeamBroadcaster for sub-50ms delivery to LiveView (bypassing the 50ms batch window)
- Registered `RequestApproval` in `@peer_tools` and added `:gate_id`/`:gate_context` to `@known_param_keys` for safe LLM param atomization
- Added `config :loomkin, :approval_gate_timeout_ms, 300_000` as the overridable system default

## Task Commits

Each task was committed atomically:

1. **Task 1: Create ApprovalRequested/Resolved signals and RequestApproval tool** - `72c09ee` (feat)
2. **Task 2: Register approval signals as critical, register tool, add app config** - `1cde5e1` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `lib/loomkin/signals/approval.ex` - Approval.Requested and Approval.Resolved signal struct modules
- `lib/loomkin/tools/request_approval.ex` - RequestApproval jido action implementing the blocking gate
- `lib/loomkin/teams/team_broadcaster.ex` - @critical_types updated with both approval signal type strings
- `lib/loomkin/tools/registry.ex` - RequestApproval in @peer_tools; :gate_id/:gate_context in @known_param_keys
- `config/config.exs` - approval_gate_timeout_ms default config added
- `test/loomkin/tools/request_approval_test.exs` - Full test suite replacing stub flunks

## Decisions Made

- Timeout param uses seconds at the invocation level (matching human-readable convention) and is converted to ms internally; app config uses ms to match Elixir timing convention
- `Application.get_env/3` called at runtime (not as module attribute) so test config can override the default timeout
- `Resolved` signal published on all three outcomes (approved, denied, timeout) to ensure LiveView always receives a close notification regardless of path
- `RequestApproval` placed in `@peer_tools` not `@lead_tools` because any team agent may need human approval, not only the lead

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Fixed import arity for `param/3`**
- **Found during:** Task 1 (compilation)
- **Issue:** Plan specified `import Loomkin.Tool, only: [param!: 2, param: 2]` but the function has arity 3 (key + default arg)
- **Fix:** Changed import to `param: 3`
- **Files modified:** lib/loomkin/tools/request_approval.ex
- **Verification:** mix compile succeeded, all tests pass
- **Committed in:** 72c09ee (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking import arity correction)
**Impact on plan:** Trivial fix required for compilation. No scope creep.

## Issues Encountered

None beyond the import arity fix above.

## Next Phase Readiness

- All server-side contracts are in place: signals, tool, registry routing, critical classification
- Plan 03 (workspace_live approval handling) can now implement `handle_info` for ApprovalRequested/Resolved and the `approve_card_agent`/`deny_card_agent` event handlers that route `:approval_response` to the blocking tool task
- Plan 04 (agent card ui) can render the approval panel using the signal type strings and CSS classes established in Plan 01

---
*Phase: 06-approval-gates*
*Completed: 2026-03-08*

## Self-Check: PASSED

- lib/loomkin/signals/approval.ex: FOUND
- lib/loomkin/tools/request_approval.ex: FOUND
- .planning/phases/06-approval-gates/06-02-SUMMARY.md: FOUND
- commit 72c09ee: FOUND
- commit 1cde5e1: FOUND
