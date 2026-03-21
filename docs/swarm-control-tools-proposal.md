# Swarm Control Tools Feasibility Study

**Date:** 2026-03-21
**Task:** #4 - Investigate swarm control tools feasibility for Loomkin
**Scope:** Research only — no implementation

---

## Executive Summary

Loomkin has **rich agent discovery and management infrastructure** but **does not expose agent listing/killing as tools agents can invoke**. The platform implements a lead/concierge orchestration model where team leads coordinate work, not peer agents. Introducing swarm control tools would require careful permission design to avoid undermining this hierarchy while unlocking legitimate use cases (team self-awareness, maintenance, adaptation).

**Key Finding:** The infrastructure exists; the decision is primarily architectural (should agents control the team structure directly?).

---

## 1. Current State: What AgentRegistry Exposes

### 1.1 AgentRegistry Overview

Loomkin uses Erlang's `Registry` module via a custom wrapper in `Loomkin.Teams.Manager`:

- **Location:** `lib/loomkin/teams/agent.ex` (agent registration via `Registry`)
- **Key pattern:** `Registry.register(Loomkin.Teams.AgentRegistry, {team_id, agent_name}, metadata_map)`
- **Metadata stored:** `%{role, status, model}`

### 1.2 Agent Lookup & Listing Functions (in Manager)

**Public API:**
- `list_agents(team_id)` → Returns `[%{name, pid, role, status, model}, ...]`
- `list_all_agents(team_id)` → Recursively lists agents in team + all sub-teams
- `find_agent(team_id, name)` → Returns `{:ok, pid}` or `:error`
- `get_team_meta(team_id)` → Returns team metadata (name, project_path, parent_id, depth)

**Status tracking:**
- Agents update their own status via `Registry.update_value` (line 2469 in agent.ex)
- Available statuses: `:idle`, `:thinking`, `:executing`, `:streaming` (inferred from agent.ex)
- Status is **optional metadata** — some agents may not set it

**Constraints:**
- No API to list agents **in other teams** (by design — cross-team queries go through explicit `CrossTeamQuery` tool)
- No agent filtering by status/role/capability
- No metric metadata (cost, request count, latency)

### 1.3 Process Lifecycle Management

**Stopping an agent:**
```elixir
# In Manager.stop_agent(team_id, name)
case find_agent(team_id, name) do
  {:ok, pid} -> Distributed.terminate_child(pid)
  :error -> :ok
end
```

- Uses `Distributed.terminate_child/1` (wrapper around supervisor termination)
- Graceful: no explicit `GenServer.stop` — relies on supervisor's shutdown sequence
- No permission checks (caller must have access to team_id)

**Canceling active loops:**
```elixir
# In Manager.cancel_all_loops(team_id)
GenServer.call(pid, :cancel, 5_000)  # Each agent handles :cancel message
```

- Agents respond to `:cancel` by shutting down active LLM tasks
- Used by workspace switching (project context change)
- **Not exposed as a tool** (internal use only)

### 1.4 What's Missing from Public API

- ❌ No tool to list agents (must go through manager directly)
- ❌ No tool to stop/kill agents (no tool exists)
- ❌ No tool to cancel active loops (internal only)
- ❌ No filtering by status/role/capability/cost
- ❌ No agent querying other teams (cross-team queries require explicit `CrossTeamQuery` tool)
- ❌ No metrics/metadata beyond name/role/status/model

---

## 2. Existing Agent Management Tools

### 2.1 Team Spawning & Discovery

| Tool | Purpose | Exposed to | Notes |
|------|---------|-----------|-------|
| `team_spawn` | Create new team + spawn agents | Lead, Concierge | Restricted to orchestration roles |
| `team_assign` | Assign task to specific agent | Lead, Concierge | Role-based task routing |
| `team_smart_assign` | Auto-assign based on capabilities | Lead, Concierge | Uses relevance scoring |
| `team_progress` | Monitor team status | Lead, Concierge | Read-only observation |
| `list_teams` | Discover sibling/child/parent teams | All roles | Hierarchical team discovery |
| `cross_team_query` | Query agents in other teams | All roles | Read-only queries only |

### 2.2 Team Control (No Fine-Grained Agent Control)

| Tool | Purpose | Exposed to | Notes |
|------|---------|-----------|-------|
| `team_dissolve` | Disband entire team | Lead, Concierge | Cascades to sub-teams; stops all agents |
| `team_comms` | Broadcast to team | Lead, Concierge | One-to-many messaging |

**Critical Gap:** There is **no tool to control individual agents within a team** (no list_team_agents, no stop_agent, no cancel_agent). Only team-level control exists.

### 2.3 Peer-to-Peer Tools (Agent Collaboration)

| Tool | Purpose | Exposed to | Notes |
|------|---------|-----------|-------|
| `peer_message` | Send message to teammate | All roles | Direct messaging, optional response |
| `peer_ask_question` | Broadcast question to team | All roles | Async; responder answers when able |
| `peer_discovery` | Announce completion + findings | All roles | Notifies interested peers |
| `peer_create_task` | Create sub-task for peer | All roles | Task dependency; peer must accept |
| `peer_complete_task` | Mark task done + attach results | All roles | Structured output for dependents |

**Observation:** Peer tools are **symmetric** — all agents can message any peer. But there's **no peer control** (no ability to ask a peer to stop, pause, or change behavior).

---

## 3. Cross-Team Safety Considerations

### 3.1 Current Cross-Team Boundary Enforcement

**Design principle:** Agents can **query** other teams but **cannot control** them.

```elixir
# CrossTeamQuery allows read-only operations:
# - List agents in another team
# - Query task status in another team's backlog
# BUT:
# - Cannot modify another team's tasks
# - Cannot spawn agents in other teams
# - Cannot message another team's agents directly
```

**How it works:**
1. Agent calls `cross_team_query` tool with target team_id
2. Tool validates `source_team_id` in context (authorization boundary)
3. Query execution is read-only (no mutations allowed)

**Potential risk if we add `stop_agent`:**
- An agent could stop agents in sibling/parent teams (unless we restrict by team_id)
- Current approach: Lead/concierge roles only; limited scope per function call

### 3.2 Scope-Based Safety (Team Nesting)

Loomkin enforces **team hierarchy** with depth limits:
- Parent teams can spawn sub-teams (up to depth 2 by default)
- Sub-teams cannot spawn further (depth limit enforced)
- Dissolving a team cascades to all sub-teams
- **Question:** Should a sub-team agent control parent team agents? Should siblings control each other?

### 3.3 Role-Based Permission Boundaries

Current tool access:
- **Lead role:** All team management tools (`team_spawn`, `team_dissolve`, etc.)
- **Concierge role:** All lead tools + orchestration mode
- **Other roles (coder, researcher, tester, reviewer):** Peer tools only (no team control)

**Implication:** If we add agent control tools, should they be restricted to lead/concierge? Or available to all agents?

---

## 4. Safety Concerns: Detailed Analysis

### 4.1 Can an Agent Kill Itself?

**Risk Level:** LOW
**Scenario:** Agent calls `stop_agent` on its own pid

```elixir
# Should this be allowed?
stop_agent(team_id, my_agent_name)  # Self-termination
```

**Concerns:**
- ✓ Could be legitimate (agent recognizes it's redundant, requests shutdown)
- ✗ Could be exploited (agent in a bad state tries to hide by exiting)
- ✗ LLM hallucination (model generates tool call by mistake)

**Recommendation:** **Allow with warning**. Agents already have agency over their behavior; if an agent decides to exit, let it. Log all self-terminations.

### 4.2 Can an Agent Kill Agents in Other Teams?

**Risk Level:** CRITICAL
**Scenario:** Agent in team A stops an agent in team B

```elixir
# Should this be allowed?
cross_team_stop_agent(target_team_id, agent_name)  # Cross-team kill
```

**Concerns:**
- ✗ Violates team autonomy (sibling team shouldn't unilaterally remove agents)
- ✗ Breaks coordination (killed agent's tasks become orphaned)
- ✗ Potential malice (rogue agent sabotages peer team)

**Current Loomkin approach:** Cross-team interactions are **read-only** (queries only). No mutations across team boundaries.

**Recommendation:** **Disallow cross-team agent control**. Keep agent killing team-scoped. If agents need to coordinate team dissolve, escalate to lead/concierge.

### 4.3 What About Killing Mid-Task?

**Risk Level:** MEDIUM
**Scenario:** Agent stops another agent while work is in flight

```elixir
# Agent B is mid-implementation; Agent A requests stop
stop_agent(team_id, agent_b_name)
```

**Concerns:**
- ✗ Data loss (mid-execution state is not saved)
- ✗ Dependency cascade (downstream tasks waiting on B's output fail)
- ✗ Inconsistent file state (B was editing files when killed)

**Current safeguards:**
- Agent shutdown is handled by supervisor (graceful termination attempt)
- But no explicit checkpoint/save before shutdown
- Tasks don't have "mid-task checkpoint" recovery (yet — Epic 6.3 planned)

**Recommendation:** **Allow, but require lead/concierge approval** if task-aware. Alternatively, implement a "request_stop" flow (agent requests permission from task owner before killing).

### 4.4 What If an Agent Kills the Lead?

**Risk Level:** HIGH
**Scenario:** Any agent stops the lead (team coordination breaks down)

```elixir
# Specialist kills the lead
stop_agent(team_id, "lead")
```

**Concerns:**
- ✗ Team leaderless (no one to assign tasks, make decisions)
- ✗ Cascading failure (sub-teams without parent lead coordination)
- ✗ Potential sabotage (hostile agent disables team function)

**Recommendation:** **Restrict agent kill to non-lead roles OR require lead/concierge approval**.

Option A: Validation in tool
```elixir
if target_role == :lead and caller_role not in [:concierge] do
  {:error, "Cannot stop lead agent"}
end
```

Option B: Restrict tool to lead/concierge only
- Lead can manage its own team (including removing team members)
- Specialist agents cannot control team structure

---

## 5. Architectural Question: Lead Model vs. Direct Swarm Control

### 5.1 Loomkin's Current Orchestration Model

**Design Philosophy:** "Intentional hierarchy through orchestration, not chaos"

- **Lead agents** make team-level decisions (spawn, assign, dissolve)
- **Specialist agents** request spawning via `team_spawn` tool (approval flow)
- **Peer agents** collaborate via messaging (lateral coordination)
- **Concierge** handles user escalations (human gate-keeping)

**Benefit:** Clear lines of responsibility; lead is accountable for team state.

### 5.2 What jido_claw Does (Reference)

jido_claw exposes **first-class swarm tools** available to all agents:
- `spawn_agent` → Create new agent
- `list_agents` → List all agents
- `send_to_agent` → Send message
- `kill_agent` → Terminate agent

**Philosophy:** "Flat hierarchy; agents are peers with direct control."

**Trade-off:** More agent autonomy, but harder to reason about team state (who authorized that kill?).

### 5.3 Loomkin's Approach: Hybrid?

Propose **limited swarm awareness without full swarm control**:
- ✓ Add `list_team_agents` (read-only team introspection)
- ✓ Restrict to lead/concierge (or make available to all with logging)
- ✗ Keep agent killing (stopping) as **lead-only operation**
- ✗ No cross-team agent control (enforces team autonomy)

**Rationale:**
- Agents can reason about team composition (awareness)
- Lead retains control over team structure (discipline)
- Supports adaptive spawning (lead decides, not agent requests)

---

## 6. Minimal Implementation Proposal

### 6.1 Tool #1: `list_team_agents`

**Purpose:** List agents in current team (no cross-team support).

**Schema:**
```elixir
use Jido.Action,
  name: "list_team_agents",
  description: "List all active agents in your team with roles, status, and model info.",
  schema: [
    team_id: [type: :string, required: true, doc: "Your team ID"],
    filter_by_role: [
      type: :string,
      doc: "Optional: filter by role (e.g. 'coder', 'researcher')"
    ],
    filter_by_status: [
      type: :string,
      doc: "Optional: filter by status (e.g. 'idle', 'thinking')"
    ]
  ]
```

**Return:**
```json
{
  "team_id": "team-abc123",
  "team_name": "Codebase Analysis",
  "agent_count": 4,
  "agents": [
    {
      "name": "alice",
      "role": "coder",
      "status": "idle",
      "model": "claude-opus-4-6",
      "pid": "#PID<0.1.0>"
    },
    {
      "name": "bob",
      "role": "researcher",
      "status": "thinking",
      "model": "claude-opus-4-6",
      "pid": "#PID<0.2.0>"
    }
  ]
}
```

**Access:**
- **Lead/Concierge:** Unrestricted (team management)
- **Other roles:** Available (read-only awareness)
- **Cross-team:** NO (use `cross_team_query` if needed)

**Implementation:**
```elixir
defmodule Loomkin.Tools.ListTeamAgents do
  use Jido.Action,
    name: "list_team_agents",
    description: "List all active agents in your team...",
    schema: [...]

  import Loomkin.Tool, only: [param!: 2, param: 3]
  alias Loomkin.Teams.Manager

  def run(params, context) do
    team_id = param!(params, :team_id)
    filter_role = param(params, :filter_by_role, nil)
    filter_status = param(params, :filter_by_status, nil)

    agents = Manager.list_agents(team_id)

    agents =
      agents
      |> filter_by_role(filter_role)
      |> filter_by_status(filter_status)

    team_name = Manager.get_team_name(team_id) || team_id

    {:ok, %{
      team_id: team_id,
      team_name: team_name,
      agent_count: length(agents),
      agents: agents
    }}
  end

  defp filter_by_role(agents, nil), do: agents
  defp filter_by_role(agents, role) do
    Enum.filter(agents, & &1.role == String.to_atom(role))
  end

  defp filter_by_status(agents, nil), do: agents
  defp filter_by_status(agents, status) do
    Enum.filter(agents, & &1.status == String.to_atom(status))
  end
end
```

### 6.2 Tool #2: `stop_agent` (Optional, Lead-Only)

**Purpose:** Gracefully terminate an agent in the current team.

**Schema:**
```elixir
use Jido.Action,
  name: "stop_agent",
  description:
    "Stop an agent in your team. Restricted to lead/concierge roles. " <>
    "Agent will shut down gracefully, but in-flight work may be lost.",
  schema: [
    team_id: [type: :string, required: true, doc: "Your team ID"],
    agent_name: [type: :string, required: true, doc: "Name of agent to stop"],
    reason: [type: :string, doc: "Optional reason (logged for audit)"]
  ]
```

**Return:**
```json
{
  "status": "stopped",
  "agent_name": "alice",
  "team_id": "team-abc123",
  "message": "Agent alice stopped gracefully"
}
```

**Access:**
- **Lead/Concierge:** Unrestricted (team management)
- **Other roles:** ERROR (role-restricted)

**Validation:**
- Cannot stop self (error: "Cannot stop yourself; request dissolution instead")
- Cannot stop lead (error: "Cannot stop lead; requires team_dissolve or lead handoff")
- Must exist in team (error: "Agent not found")

**Implementation Sketch:**
```elixir
defmodule Loomkin.Tools.StopAgent do
  use Jido.Action,
    name: "stop_agent",
    description: "Stop an agent in your team (lead/concierge only)...",
    schema: [...]

  def run(params, context) do
    team_id = param!(params, :team_id)
    agent_name = param!(params, :agent_name)
    reason = param(params, :reason, "No reason provided")
    caller_role = param(context, :role)

    # Permission check
    unless caller_role in [:lead, :concierge] do
      {:error, "stop_agent is restricted to lead/concierge roles"}
    end

    # Get agent info
    case Manager.find_agent(team_id, agent_name) do
      {:error, :not_found} ->
        {:error, "Agent '#{agent_name}' not found in team"}

      {:ok, agent_info} ->
        # Check if trying to stop self
        if agent_name == context[:agent_name] do
          {:error, "Cannot stop yourself"}
        end

        # Check if trying to stop lead
        if agent_info.role == :lead do
          {:error, "Cannot stop lead; use team_dissolve or transfer leadership"}
        end

        # Log audit trail
        Logger.info(
          "[Kin:stop_agent] team=#{team_id} agent=#{agent_name} " <>
          "caller=#{context[:agent_name]} reason=#{reason}"
        )

        # Stop the agent
        Manager.stop_agent(team_id, agent_name)

        {:ok, %{
          status: "stopped",
          agent_name: agent_name,
          team_id: team_id,
          message: "Agent #{agent_name} stopped gracefully"
        }}
    end
  end
end
```

---

## 7. Which Tool to Add First?

### 7.1 Recommendation: Start with `list_team_agents` only

**Why `list_team_agents` first:**
- ✓ Zero safety risk (read-only)
- ✓ Immediate value (agents understand team composition)
- ✓ Foundation for smarter self-adaptation (know when to spawn, when not)
- ✓ No permission model needed (make available to all)
- ✓ Supports adaptive orchestration (lead can decide spawn timing based on team state)

**Why defer `stop_agent`:**
- ✗ Requires careful permission model (lead-only vs. all)
- ✗ Needs audit logging (who stopped whom, why?)
- ✗ Raises questions about mid-task shutdown (data loss risk)
- ✗ Only solves "team cleanup" — lead already has `team_dissolve`
- ✗ Not blocking any current workflows (lead can stop agents manually via workspace UI)

### 7.2 Implementation Estimate

**`list_team_agents`:**
- Implementation: 1-2 hours (wrapper around Manager.list_agents + filtering)
- Testing: 1 hour (unit tests + integration tests)
- Docs: 0.5 hours
- **Total: 2.5-3.5 hours**

**`stop_agent`:**
- Implementation: 2-3 hours (permissioning + audit logging)
- Testing: 1.5 hours (permission checks, edge cases)
- Docs: 0.5 hours
- **Total: 4-5 hours**

---

## 8. Open Questions & Risks

### 8.1 Questions for Product

1. **Team self-awareness:** Should agents actively monitor team composition and adapt (e.g., spawn new agents if a specialist is missing)? Or is that the lead's job?

2. **Cross-team visibility:** Should agents be able to see agents in sibling teams? (Currently: no, by design.)

3. **Status accuracy:** Agent status metadata is optional and may be stale. Should we track this more carefully, or treat status as a hint, not ground truth?

4. **Cost tracking:** Should `list_team_agents` return cost/token metrics for each agent? (Needed for adaptive spawning decisions.)

5. **Self-stopping ethics:** If an agent recognizes it's in a bad state and stops itself, is that healthy autonomy or hidden failure? How do we distinguish?

### 8.2 Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Agent spawns copies of itself in a loop | MEDIUM | Don't expose spawn_agent to all roles; lead-only with budget checks |
| Agent stops critical team members (lead, coder) | MEDIUM | Validation in stop_agent; restrict to lead/concierge |
| Self-stopping agent hides bugs | LOW | Log all self-terminations; alert on unexpected exits |
| Cross-team control undermines autonomy | HIGH | Enforce team-scoped operations; cross-team queries are read-only |
| Status metadata is stale/wrong | LOW | Document status as "hints, not guarantees"; query live agent pids if needed |

---

## 9. Recommendations Summary

### 9.1 What to Implement

| Tool | Priority | Timeline | Safety |
|------|----------|----------|--------|
| `list_team_agents` | HIGH | Next sprint | ✓ Read-only, no risks |
| `stop_agent` (lead-only) | MEDIUM | Backlog | ✓ Permission-gated, audit-logged |

### 9.2 What NOT to Implement

- ❌ Cross-team agent control (violates team autonomy)
- ❌ Direct agent-to-agent messages (use peer_message instead)
- ❌ Spawning agents outside your team (use team_spawn with parent approval)
- ❌ Capability-based dynamic role changes (use peer_change_role for explicit negotiation)

### 9.3 Future Extensions (Post-List)

Once `list_team_agents` exists, consider:
- **Adaptive spawning:** Lead uses list + team progress to decide when new specialists are needed
- **Health monitoring:** Agents that repeatedly fail get flagged; lead decides whether to keep them
- **Cost-aware assignment:** List agents, filter by cost metrics, assign tasks to cheapest capable agent
- **Team composition queries:** "How many coders do we have?" → Decision log entries for team evolution

---

## Appendix: Code Locations

| Entity | Location |
|--------|----------|
| AgentRegistry usage | `lib/loomkin/teams/agent.ex` lines 78-79, 329 |
| Manager.list_agents | `lib/loomkin/teams/manager.ex` lines 326-365 |
| Manager.stop_agent | `lib/loomkin/teams/manager.ex` lines 315-324 |
| Manager.cancel_all_loops | `lib/loomkin/teams/manager.ex` lines 297-313 |
| Role tool assignments | `lib/loomkin/teams/role.ex` lines 178-204 |
| Existing team tools | `lib/loomkin/tools/team_*.ex` (spawn, assign, progress, etc.) |
| Cross-team boundaries | `lib/loomkin/teams/agent.ex` agent loop; cross_team_query tool |

---

## Conclusion

Loomkin's AgentRegistry and Manager API **already support agent listing and stopping**. The question is not "can we do this?" but "**should agents have direct control over team composition?**"

The recommendation is to **start conservatively**:
1. Add `list_team_agents` (read-only awareness) — HIGH priority, immediate value
2. Defer `stop_agent` (team control) — MEDIUM priority, needs more design work

This balances **agent autonomy** (understanding team state) with **orchestration discipline** (lead retains control over team structure).
