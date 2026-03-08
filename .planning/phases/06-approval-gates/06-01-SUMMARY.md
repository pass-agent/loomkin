---
phase: 06-approval-gates
plan: "01"
subsystem: testing
tags: [tdd, approval-gates, test-stubs, nyquist]
dependency_graph:
  requires: []
  provides:
    - failing test stubs for Loomkin.Tools.RequestApproval (Plans 02+)
    - failing test stubs for workspace_live approve/deny event handlers (Plan 03)
    - failing test stubs for leader approval banner assigns (Plan 03)
    - failing broadcaster critical_type stubs for approval signals (Plan 02)
    - failing agent card approval panel and dot class stubs (Plan 04)
  affects:
    - test/loomkin/tools/request_approval_test.exs
    - test/loomkin/teams/team_broadcaster_test.exs
    - test/loomkin_web/live/agent_card_component_test.exs
    - test/loomkin_web/live/workspace_live_approval_test.exs
tech_stack:
  added: []
  patterns:
    - flunk("not implemented") stubs for compile-clean red tests
    - Code.ensure_loaded? for module existence check
key_files:
  created:
    - test/loomkin/tools/request_approval_test.exs
    - test/loomkin_web/live/workspace_live_approval_test.exs
  modified:
    - test/loomkin_web/live/agent_card_component_test.exs
    - test/loomkin/teams/team_broadcaster_test.exs
decisions:
  - "approval_pending dot class target is bg-violet-500 animate-pulse (not amber)"
  - "approval gate card wrapper class is agent-card-approval (not agent-card-blocked)"
  - "approval signal types agent.approval.requested and agent.approval.resolved must be critical"
  - "leader_approval_pending assign tracks banner visibility in workspace_live"
metrics:
  duration: 2 minutes
  completed_date: "2026-03-08"
  tasks_completed: 2
  files_modified: 4
---

# Phase 6 Plan 1: Approval Gate Test Stubs Summary

Failing test stubs written for all approval gate behaviors ahead of any implementation — Nyquist compliance for Plans 02-04.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create request_approval_test.exs and workspace_live_approval_test.exs stubs | cc51937 | test/loomkin/tools/request_approval_test.exs, test/loomkin_web/live/workspace_live_approval_test.exs |
| 2 | Update agent_card_component_test.exs and team_broadcaster_test.exs stubs | 1074196 | test/loomkin_web/live/agent_card_component_test.exs, test/loomkin/teams/team_broadcaster_test.exs |

## What Was Built

Created two new test files and updated two existing ones, producing 13 new failing tests that define the approval gate contract:

**New files:**
- `test/loomkin/tools/request_approval_test.exs` — 4 tests: module existence, run/2 approved response, run/2 timeout response, registry cleanup. All fail (module does not exist yet).
- `test/loomkin_web/live/workspace_live_approval_test.exs` — 4 tests: approve_card_agent routing, deny_card_agent routing, leader banner set on ApprovalRequested signal, leader banner cleared on ApprovalResolved. All flunk stubs.

**Updated files:**
- `test/loomkin_web/live/agent_card_component_test.exs` — Updated existing amber dot assertion to violet (now failing). Added two new failing stubs: approval panel render and card_state_class using agent-card-approval.
- `test/loomkin/teams/team_broadcaster_test.exs` — Added two new failing stubs: agent.approval.requested and agent.approval.resolved classified as critical signal types.

## Test State After Plan

- 34 tests run across all four files
- 13 failures (all new approval gate stubs — expected)
- 21 passing (all pre-existing tests — no regressions)

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check

Files exist:
- test/loomkin/tools/request_approval_test.exs: FOUND
- test/loomkin_web/live/workspace_live_approval_test.exs: FOUND
- test/loomkin_web/live/agent_card_component_test.exs: FOUND (modified)
- test/loomkin/teams/team_broadcaster_test.exs: FOUND (modified)

Commits exist:
- cc51937: FOUND
- 1074196: FOUND

## Self-Check: PASSED
