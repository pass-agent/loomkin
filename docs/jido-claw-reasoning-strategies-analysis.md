# Loomkin vs jido_claw: Reasoning Strategies Analysis

**Date:** 2026-03-21 (revised)
**Status:** Conclusions finalized

---

## Executive Summary

jido_claw offers 8 pluggable reasoning strategies (ReAct, CoT, CoD, ToT, GoT, AoT, TRM, Adaptive)
with per-session switching and complexity-aware routing. After investigation, we concluded that
**Loomkin's multi-agent architecture already achieves what most of these strategies simulate
with a single agent**. The kin *are* the reasoning strategies.

We adopt selectively: complexity scoring for orchestration and CoD for token efficiency.
We do NOT adopt per-session strategy switching, GoT/AoT/TRM as individual strategies, or a
strategy marketplace UI.

---

## Part 1: What Loomkin Has Today

### Strategy Dispatch

```elixir
# lib/loomkin/agent_loop.ex:66-75
case config.reasoning_strategy do
  :react -> run_with_rate_limit_retry(messages, config, 0)  # Full tool loop
  strategy when strategy in [:cot, :cod, :tot, :adaptive] ->
    Loomkin.AgentLoop.Strategies.run(strategy, messages, config)  # Single LLM pass, no tools
  _unknown -> run_with_rate_limit_retry(messages, config, 0)  # Fallback to ReAct
end
```

### Role Defaults

Every built-in role defaults to `:react` (`role.ex:578-882`). Non-ReAct strategies exist
but are never used by any role in practice.

### Non-ReAct Strategies Skip Tools

`Strategies.run/3` does a single `Jido.AI.generate_text/2` call with a strategy-specific
system prompt suffix. No tool loop. This means switching a working agent to `:cot` would
remove its ability to use tools — a downgrade, not an upgrade.

### Adaptive Falls Back

The adaptive resolver computes a complexity score and recommends a strategy, but if it
recommends GoT/AoT/TRM, Loomkin falls back to `:cot` since those aren't wired up
(`strategies.ex:171`). The complexity score itself is discarded.

---

## Part 2: What jido_claw Does Differently

| Capability | jido_claw | Loomkin |
|-----------|-----------|---------|
| Strategy count | 8 | 5 (3 not wired) |
| Runtime switching | Per-session override | Locked per-role |
| Complexity routing | Score drives strategy + budget + timeout | Score discarded |
| Strategy registry | Pluggable, configurable | Hardcoded dispatch |

jido_claw's advantage is **strategy selection as a first-class citizen** — not the
strategies themselves.

---

## Part 3: Why Loomkin Doesn't Need Most of These

### Multi-agent patterns already cover single-agent reasoning strategies

| Single-Agent Strategy | Loomkin Multi-Agent Equivalent | Why Kin > Strategy |
|----------------------|-------------------------------|-------------------|
| **ToT** — explore 3 approaches, pick best | Spawn 3 researchers who each explore a path; lead synthesizes | Actual parallel exploration across separate LLM contexts, not one model pretending to branch |
| **GoT** — merge partial reasoning into graph | Decision graph captures this at team level across agents | Persistent, auditable, cross-session. Not ephemeral single-pass reasoning |
| **TRM** — generate, critique, refine | Coder -> reviewer -> coder loop | Real critique from a separate agent with a different system prompt beats self-critique |
| **Multi-perspective deliberation** | `spawn_conversation` with `design_review` or `red_team` templates | Full multi-agent deliberation with persona-driven reasoning (Epic 13, deployed) |

**The philosophy:** When a task is complex, don't make one agent think harder — give it
more kin to think *with*.

---

## Part 4: What We ARE Adopting

### 1. Complexity Scores as Orchestration Signals (P1)

**What:** Emit `Jido.AI.Reasoning.Adaptive.Strategy.analyze_prompt/1` scores via telemetry.
Use high scores to inform orchestration decisions — not to switch reasoning modes.

**How it works in Loomkin's model:**
- Low complexity (< 0.3) → Agent handles directly via ReAct
- Medium complexity (0.3-0.7) → Agent proceeds but lead monitors more closely
- High complexity (> 0.7) → Signal to lead/concierge to spawn a conversation or sub-team

The complexity score becomes a **spawn signal**, not a strategy switch. This is the
Loomkin-native equivalent of jido_claw's complexity-aware routing.

**Implementation:**
```elixir
# In agent_loop.ex, before entering the ReAct loop:
{_strategy, complexity_score, task_type} =
  Jido.AI.Reasoning.Adaptive.Strategy.analyze_prompt(latest_prompt)

:telemetry.execute(
  [:loomkin, :agent_loop, :complexity_detected],
  %{complexity_score: complexity_score},
  %{task_type: task_type, agent_name: config.agent_name, team_id: config.team_id}
)

# Lead/concierge can subscribe to this telemetry and decide whether to spawn help
```

**Effort:** 1 day (telemetry emission + lead prompt guidance for high-complexity response)

### 2. CoD for Internal ReAct Deliberation (P1)

**What:** Within the ReAct tool loop, use Chain-of-Draft style concise prompting for the
"thinking about what to do next" steps. The tool loop itself doesn't change — just the
internal reasoning gets cheaper.

**Why:** ReAct agents spend significant tokens on verbose internal deliberation between
tool calls. CoD-style prompting ("minimal draft steps, 5 words per step") can reduce this
without losing decision quality.

**Implementation approach:** Add a system prompt hint that encourages concise intermediate
reasoning while preserving verbose final outputs. This is prompt engineering within the
existing ReAct loop, not a strategy switch.

**Effort:** 1 day (prompt tuning + token spend measurement before/after)

### 3. Per-Turn Adaptive Intelligence (P2, future)

**What:** Within the ReAct loop, assess per-turn complexity to decide: "Is this turn simple
enough for a direct tool call, or should I pause and deliberate before acting?"

**Why:** This makes the agent loop itself smarter without switching strategies. An agent
facing a simple "read this file" turn doesn't need deep reasoning, but an agent facing
"choose between 3 architectural approaches" within the same session might benefit from a
deliberation pause.

**Effort:** 2 days (complexity check per turn + deliberation injection)

---

## Part 5: What We Are NOT Adopting

| Feature | Why Not |
|---------|---------|
| Per-session strategy switching | Agents need tools (ReAct). Switching to non-tool strategies removes capabilities. When deeper reasoning is needed, spawn a conversation instead. |
| GoT/AoT/TRM as strategies | These are single-agent approximations of what Loomkin does natively with multiple kin. Adding them would be a step backward. |
| Strategy Registry / marketplace UI | Over-engineering. The orchestration layer (lead/concierge deciding when to spawn sub-teams) IS Loomkin's strategy selector. |
| Strategy configuration per-role | All roles should use ReAct (tool access). Strategy variation comes from role specialization and team composition, not prompt mode. |

---

## Part 6: Reference — jido_ai Strategy Details

For future reference, here are all 8 strategies available in jido_ai:

| Strategy | Temperature | Tools? | Best For |
|----------|-------------|--------|----------|
| ReAct | default | Yes | Tool-heavy tasks (Loomkin's default, keep it) |
| CoT | 0.2 | No | Step-by-step analysis |
| CoD | 0.1 | No | Token-efficient reasoning |
| ToT | 0.4 | No | Multi-path exploration |
| GoT | varies | No | Multi-perspective synthesis |
| AoT | 0.0 | No | Algorithmic exploration |
| TRM | varies | No | Iterative refinement |
| Adaptive | varies | Depends | Auto-selects based on complexity |

All non-ReAct strategies skip the tool loop (single LLM pass). This is the fundamental
reason they don't fit Loomkin's agent model — kin need tools to do their jobs.

---

## Conclusion

jido_claw's strategy system is well-designed for a single-agent platform. But Loomkin is a
multi-agent platform. The things jido_claw achieves with prompt-level reasoning strategies,
Loomkin achieves with actual agent collaboration:

- **Diverse perspectives** → spawn multiple kin with different roles
- **Iterative refinement** → coder/reviewer loops
- **Exploration** → parallel researcher teams
- **Deliberation** → conversation agents (Epic 13)

What we take: **complexity awareness** (the scores) and **token efficiency** (CoD-style
concise deliberation). What we leave: everything that would duplicate what kin collaboration
already provides.
