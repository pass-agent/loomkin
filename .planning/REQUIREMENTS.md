# Requirements: Agent Orchestration Visibility & Control

**Defined:** 2026-03-07
**Core Value:** Humans can see exactly what agents are doing and saying to each other in real-time, and intervene naturally at any moment — without breaking the autonomous flow.

## v1 Requirements

### Foundation

- [x] **FOUN-01**: LiveView components extracted from workspace_live.ex monolith into focused LiveComponents (agent cards, comms feed, team dashboard, inspector, etc.)
- [x] **FOUN-02**: TeamBroadcaster aggregator GenServer sits between Signal Bus and LiveView to batch and throttle events, preventing mailbox overload
- [x] **FOUN-03**: Signal Bus subscriptions cleaned up with unsubscribe in terminate/2 and Topics module for topic string management

### Live Visibility

- [x] **VISB-01**: Agent-to-agent messages visible in real-time comms feed for dynamically spawned sub-teams (bus subscription wired for dynamic team join)
- [x] **VISB-02**: Newly spawned agents auto-insert into comms feed and agent card grid without page reload
- [x] **VISB-03**: Task dependency graph displays blocked-by relationships visually (not just flat list)
- [ ] **VISB-04**: OTP crash recovery reflected in UI — crashed agent restarts show recovered status with no manual refresh

### Human Intervention

- [ ] **INTV-01**: Human can broadcast a chat message to the entire team conversation (not just reply-to-agent)
- [ ] **INTV-02**: Approval gates where agents pause at critical junctures and await human sign-off (distinct signal type from permission hooks)
- [ ] **INTV-03**: Agents auto-ask human when uncertain via confidence-threshold triggers from AgentLoop
- [ ] **INTV-04**: Typed state machine separates pause vs permission vs approval gate states to prevent clobbering

### Dynamic Tree

- [ ] **TREE-01**: Nested sub-teams at arbitrary depth auto-appear in the UI via recursive subscription
- [ ] **TREE-02**: ChildTeamCreated signal published from Manager.create_sub_team/3 with Process.monitor and ownership-aware termination
- [ ] **TREE-03**: Pre-spawn budget check and approval gate before spawning expensive sub-trees

### Leader Protocol

- [ ] **LEAD-01**: Leader agent spawns research sub-agents, synthesizes findings, then poses informed questions to human
- [ ] **LEAD-02**: Leader role config with research orchestration prompts and multi-step protocol

## v2 Requirements

### Collaborative Steering

- **COLLAB-01**: Multiple humans can view and steer the same team session collaboratively
- **COLLAB-02**: Shared cursor/presence indicators for co-steering humans

### Cross-Platform

- **XPLAT-01**: Discord/Telegram orchestration UI for monitoring teams from chat platforms
- **XPLAT-02**: Mobile-responsive layout for monitoring (read-only) on small screens

### Advanced Orchestration

- **ORCH-01**: Full conversation replay/audit log UI for post-hoc analysis
- **ORCH-02**: Leader autonomously determines tree depth with cost-bounded complexity heuristic
- **ORCH-03**: Agent persona/personality configuration UI

## Out of Scope

| Feature | Reason |
|---------|--------|
| Multi-user collaborative steering | Concurrent human operators on the same team creates conflict — explicit future milestone |
| Custom agent persona builder | Personality/voice customization is vanity; focus is orchestration mechanics |
| External webhook triggers (Zapier) | Different product surface entirely |
| Mobile-responsive orchestration UI | Mission control density incompatible with small screens |
| Real-time analytics dashboards (P99) | Telemetry exists but performance dashboards conflate monitoring with orchestration |
| Per-message undo/rollback | Reversing agent actions on persisted files/git is dangerous without careful design |
| Agent "brain" custom system prompts UI | Risky for non-developers; role configs remain code-level |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| FOUN-01 | Phase 1 — Monolith Extraction | Complete |
| FOUN-02 | Phase 2 — Signal Infrastructure | Complete |
| FOUN-03 | Phase 2 — Signal Infrastructure | Complete |
| VISB-01 | Phase 3 — Live Comms Feed | In Progress (03-01 complete) |
| VISB-02 | Phase 3 — Live Comms Feed | In Progress (03-01 complete) |
| VISB-03 | Phase 4 — Task Graph & Crash Recovery | Complete |
| VISB-04 | Phase 4 — Task Graph & Crash Recovery | In Progress (04-01 signals complete) |
| INTV-01 | Phase 5 — Chat Injection & State Machines | Pending |
| INTV-04 | Phase 5 — Chat Injection & State Machines | Pending |
| INTV-02 | Phase 6 — Approval Gates | Pending |
| INTV-03 | Phase 7 — Confidence Triggers | Pending |
| TREE-01 | Phase 8 — Dynamic Tree Visibility | Pending |
| TREE-02 | Phase 8 — Dynamic Tree Visibility | Pending |
| TREE-03 | Phase 9 — Spawn Safety | Pending |
| LEAD-01 | Phase 10 — Leader Research Protocol | Pending |
| LEAD-02 | Phase 10 — Leader Research Protocol | Pending |

**Coverage:**
- v1 requirements: 16 total
- Mapped to phases: 16
- Unmapped: 0

---
*Requirements defined: 2026-03-07*
*Last updated: 2026-03-07 — traceability filled after roadmap creation*
