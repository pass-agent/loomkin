# Epic 14: Self-Healing Agent Teams

## Overview

When an agent encounters a failure — a bug, a lint error, a command that exits non-zero, a tool that returns an error — it currently does what any LLM-based agent does: tries to fix it itself. This is suboptimal for three reasons:

1. **Context pollution**: The working agent's conversation history gets cluttered with debugging back-and-forth, diluting focus on its actual task
2. **Wrong expertise**: A coder agent deep in implementation isn't necessarily the best diagnostician. Diagnosis and repair are distinct skills
3. **Wasted iterations**: The agent burns LLM iterations on trial-and-error fixes instead of productive work

The self-healing system introduces a **separation of concerns** for error recovery. When an agent hits a failure, it **suspends** — freezing its state and yielding control. A dedicated **Diagnostician** agent spawns to analyze the root cause. Once diagnosed, a **Fixer** agent spawns to apply the repair. When the fix is confirmed, the original agent **wakes up** and continues from exactly where it left off, with a brief summary injected: "the issue was X, it's resolved, continue."

This mirrors how real engineering teams work: the person writing code doesn't stop to investigate CI failures — someone else triages, someone else fixes, and the original developer picks back up.

### Use Cases

- **Coder agent gets a compile error** → suspends → diagnostician reads LSP diagnostics, identifies missing import → fixer adds the import → coder resumes
- **Researcher agent's shell command fails** → suspends → diagnostician analyzes exit code and stderr → fixer adjusts the command or installs a dependency → researcher resumes
- **Tester agent encounters a flaky test** → suspends → diagnostician identifies the race condition → fixer adds synchronization → tester resumes
- **Any agent hits a lint/format violation** → suspends → diagnostician identifies the rule → fixer runs `mix format` or applies the style fix → agent resumes
- **Lead agent's sub-team spawn fails** → suspends → diagnostician checks budget/depth limits → fixer adjusts parameters or requests approval → lead resumes

## Architecture

```
Agent (working)
    │
    │ encounters error
    │
    ▼
┌──────────────────────────────────┐
│ Error Classifier                 │
│ (in agent_loop.ex)               │
│                                  │
│ Determines: healable? severity?  │
│ Categories: compile, runtime,    │
│   lint, command, tool, resource  │
└──────────────┬───────────────────┘
               │ healable error
               ▼
┌──────────────────────────────────┐
│ Agent suspends                   │
│ - Freezes messages, task, state  │
│ - Status → :suspended_healing    │
│ - Emits agent.healing.requested  │
└──────────────┬───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│ HealingOrchestrator (GenServer)  │
│                                  │
│ 1. Spawns Diagnostician agent    │
│ 2. Waits for diagnosis           │
│ 3. Spawns Fixer agent            │
│ 4. Waits for fix confirmation    │
│ 5. Wakes original agent          │
└──────────────┬───────────────────┘
               │
               ▼
┌──────────────────────────────────┐
│ Diagnostician Agent              │
│                                  │
│ Tools: LspDiagnostics, FileRead, │
│   ContentSearch, Shell (read),   │
│   DiagnosisReport                │
│                                  │
│ Analyzes error, identifies root  │
│ cause, writes structured report  │
└──────────────┬───────────────────┘
               │ diagnosis report
               ▼
┌──────────────────────────────────┐
│ Fixer Agent                      │
│                                  │
│ Tools: FileEdit, FileWrite,      │
│   Shell, Git, LspDiagnostics,    │
│   FixConfirmation                │
│                                  │
│ Applies targeted fix based on    │
│ diagnosis, verifies it worked    │
└──────────────┬───────────────────┘
               │ fix confirmed
               ▼
┌──────────────────────────────────┐
│ Agent wakes up                   │
│ - Status → previous status       │
│ - Injects summary message        │
│ - Resumes agent loop             │
└──────────────────────────────────┘
```

### Key Design Decisions

1. **Suspend, don't crash**: The original agent's GenServer stays alive with frozen state. No restart, no lost context. The checkpoint system (epic 6.3) provides the pause/resume primitive we build on

2. **Two-phase healing (diagnose then fix)**: Separating diagnosis from repair lets each agent focus on one job. The diagnostician is read-only and analytical. The fixer is write-capable and targeted. This prevents a single agent from thrashing between "what's wrong?" and "let me try this"

3. **Lightweight ephemeral agents**: Diagnostician and fixer agents are short-lived — they spawn, do their job, and dissolve. They don't persist as team members. This keeps team composition clean

4. **Error classification at the loop level**: The agent loop already detects `tool_error` events. We add classification logic there to determine if an error is healable vs. fatal vs. ignorable, avoiding unnecessary healing spawns for trivial issues

5. **Healing budget**: Each healing cycle has a max iteration cap and cost ceiling. If the diagnostician or fixer can't resolve it within budget, the error escalates to the lead agent or user — preventing infinite healing loops

6. **Injection over replay**: When the original agent wakes up, it receives a single injected message summarizing the fix — not a replay of the entire healing conversation. This keeps context clean

7. **Opt-in per role**: Not all agent roles should auto-heal. A lead agent making strategic decisions shouldn't suspend for a minor tool error. Healing behavior is configurable per role in `RoleConfig`

## Dependencies

- **Epic 6.3 (Interruptible Checkpoints)**: Provides the pause/resume primitive for agent suspension. If 6.3 is not complete, 14.5 must implement a simpler suspension mechanism directly
- **Existing infrastructure**: `LspDiagnostics` tool, Signal bus, `AgentWatcher`, checkpoint system, sub-agent spawning

---

## 14.1: Error Classification & Healing Triggers

**Complexity**: Medium
**Dependencies**: None
**Description**: Define the error taxonomy and classification logic that determines whether an error should trigger the self-healing flow, be retried by the agent itself, or be escalated immediately.

**Files to create**:
- `lib/loomkin/healing/error_classifier.ex` — Classifies tool errors and agent failures into healing categories

**Files to modify**:
- `lib/loomkin/agent_loop.ex` — Hook classifier into `record_tool_result` and loop error paths

### Error Categories

```elixir
defmodule Loomkin.Healing.ErrorClassifier do
  @type error_category ::
    :compile_error     # Syntax errors, missing modules, type mismatches
    | :lint_error      # Format violations, credo warnings, style issues
    | :command_failure  # Non-zero exit codes from shell commands
    | :test_failure    # Test assertions failing
    | :tool_error      # Tool-specific failures (file not found, permission denied)
    | :resource_error  # Rate limits, timeouts, budget exceeded
    | :unknown         # Unclassifiable errors

  @type severity :: :low | :medium | :high | :critical

  @type classification :: %{
    category: error_category(),
    severity: severity(),
    healable: boolean(),
    error_context: map(),
    suggested_approach: String.t()
  }

  @doc """
  Classify an error from tool output or agent loop failure.
  Returns a classification with category, severity, and healability.
  """
  @spec classify(String.t(), map()) :: classification()
  def classify(error_text, context \\ %{})

  @doc """
  Determine if this error should trigger healing or if the agent
  should handle it inline. Low-severity errors (e.g., a single
  format warning) may not warrant spawning healing agents.
  """
  @spec should_heal?(classification(), map()) :: boolean()
  def should_heal?(classification, agent_state)
end
```

### Classification Logic

The classifier uses pattern matching on error text and context:

1. **Compile errors**: Match on "** (CompileError)", "undefined function", "module .* is not available", LSP error diagnostics
2. **Lint errors**: Match on "mix format", "credo", style rule violations
3. **Command failures**: Match on "Exit code:" with non-zero, stderr patterns
4. **Test failures**: Match on "test .* FAILED", assertion errors
5. **Tool errors**: Match on specific tool error prefixes ("File not found", "Permission denied")
6. **Resource errors**: Match on "rate limit", "timeout", "budget exceeded"

### Healability Rules

```elixir
# Healable: errors the system can reasonably fix automatically
defp healable?(:compile_error, _context), do: true
defp healable?(:lint_error, _context), do: true
defp healable?(:command_failure, %{retry_count: n}) when n < 2, do: true
defp healable?(:test_failure, _context), do: true
defp healable?(:tool_error, %{tool_name: name}) when name in ~w(file_edit file_write shell), do: true

# Not healable: requires human intervention or is a systemic issue
defp healable?(:resource_error, _context), do: false
defp healable?(:unknown, _context), do: false
```

### Severity Thresholds

Not every healable error should trigger healing. The `should_heal?/2` function considers:

- **Agent's `failure_count`**: Only trigger after N consecutive failures (default: 1 for compile errors, 2 for command failures)
- **Error severity**: `:low` severity errors (single format warning) → agent retries inline; `:medium`+ → healing flow
- **Role configuration**: Some roles opt out of auto-healing (configurable)
- **Healing budget remaining**: If the team has already exhausted healing budget, escalate instead

**Acceptance Criteria**:
- [ ] `ErrorClassifier.classify/2` correctly categorizes compile errors, lint errors, command failures, test failures, tool errors, and resource errors
- [ ] `should_heal?/2` returns `false` for resource errors and unknown errors
- [ ] `should_heal?/2` respects `failure_count` thresholds per category
- [ ] Classification includes `suggested_approach` text for diagnostician context
- [ ] Pattern matching handles multi-line error text (not just first line)
- [ ] At least 20 test cases covering each error category and edge cases

---

## 14.2: Agent Suspension & Wake Protocol

**Complexity**: Large
**Dependencies**: 14.1
**Description**: Extend the Agent GenServer with suspension and wake states. When healing is triggered, the agent freezes its loop, preserves full state, and transitions to `:suspended_healing`. On wake, it resumes from the exact checkpoint with an injected summary message.

**Files to modify**:
- `lib/loomkin/teams/agent.ex` — Add `:suspended_healing` status, suspension/wake handlers, state snapshot
- `lib/loomkin/agent_loop.ex` — Add healing trigger point after error classification
- `lib/loomkin/signals/agent.ex` — Add `HealingRequested`, `HealingComplete` signal types

### Suspension Flow

When `should_heal?/2` returns `true` during agent loop execution:

```elixir
# In agent_loop.ex, after detecting a healable error:
defp maybe_trigger_healing(messages, config, classification) do
  if ErrorClassifier.should_heal?(classification, %{failure_count: config.failure_count}) do
    # Return a healing signal instead of continuing the loop
    {:healing_needed, %{
      classification: classification,
      messages: messages,
      iteration: config.iteration,
      last_tool_call: config.last_tool_call
    }}
  else
    :continue
  end
end
```

### Agent State During Suspension

```elixir
# In agent.ex, handle the healing trigger from the loop
def handle_info({:loop_result, {:healing_needed, healing_context}}, state) do
  frozen_state = %{
    messages: state.messages,
    task: state.task,
    context: state.context,
    iteration: healing_context.iteration,
    cost_usd: state.cost_usd,
    tokens_used: state.tokens_used,
    loop_task_ref: state.loop_task_ref
  }

  state =
    state
    |> Map.put(:status, :suspended_healing)
    |> Map.put(:frozen_state, frozen_state)
    |> Map.put(:loop_task_ref, nil)

  # Publish suspension signal
  signal = Loomkin.Signals.Agent.HealingRequested.new!(%{
    agent_name: state.name,
    team_id: state.team_id,
    classification: healing_context.classification,
    error_context: healing_context.classification.error_context
  })
  Loomkin.Signals.publish(signal)

  # Request healing from orchestrator
  Loomkin.Healing.Orchestrator.request_healing(
    state.team_id,
    state.name,
    healing_context
  )

  {:noreply, state}
end
```

### Wake Protocol

```elixir
# Called by HealingOrchestrator when fix is confirmed
def handle_cast({:wake_from_healing, healing_summary}, state) do
  case state.status do
    :suspended_healing ->
      # Inject summary message into conversation
      summary_msg = %{
        role: :system,
        content: """
        [Healing complete] #{healing_summary.description}
        Root cause: #{healing_summary.root_cause}
        Fix applied: #{healing_summary.fix_description}
        Continue your previous task.
        """
      }

      restored_messages = state.frozen_state.messages ++ [summary_msg]

      state =
        state
        |> Map.put(:status, :idle)
        |> Map.put(:messages, restored_messages)
        |> Map.put(:frozen_state, nil)
        |> Map.put(:failure_count, 0)

      # Publish wake signal
      signal = Loomkin.Signals.Agent.HealingComplete.new!(%{
        agent_name: state.name,
        team_id: state.team_id,
        healing_summary: healing_summary
      })
      Loomkin.Signals.publish(signal)

      # Re-run the agent loop from where it left off
      state = run_loop(state)

      {:noreply, state}

    _other ->
      {:noreply, state}
  end
end
```

### New Signal Types

```elixir
# In lib/loomkin/signals/agent.ex
defmodule HealingRequested do
  use Jido.Signal,
    type: "agent.healing.requested",
    schema: [
      agent_name: [type: :string, required: true],
      team_id: [type: :string, required: true],
      classification: [type: :map, required: true],
      error_context: [type: :map, required: false]
    ]
end

defmodule HealingComplete do
  use Jido.Signal,
    type: "agent.healing.complete",
    schema: [
      agent_name: [type: :string, required: true],
      team_id: [type: :string, required: true],
      healing_summary: [type: :map, required: true]
    ]
end
```

**Acceptance Criteria**:
- [ ] Agent transitions to `:suspended_healing` status when healing is triggered
- [ ] Frozen state preserves messages, task, context, iteration count, and cost
- [ ] Agent rejects new task assignments while in `:suspended_healing` status
- [ ] Agent rejects new messages while suspended (queues them for post-wake)
- [ ] Wake injects a single summary message and resumes the agent loop
- [ ] `failure_count` resets to 0 after successful healing
- [ ] `HealingRequested` signal is published with classification data
- [ ] `HealingComplete` signal is published with summary data
- [ ] Agent handles wake for a status that is not `:suspended_healing` gracefully (no-op)
- [ ] Suspended agent's PubSub subscriptions remain active (it still receives context updates)

---

## 14.3: Healing Orchestrator

**Complexity**: Large
**Dependencies**: 14.1, 14.2
**Description**: The central coordinator that manages the heal-diagnose-fix-resume lifecycle. Receives healing requests, spawns ephemeral diagnostician and fixer agents, tracks healing progress, enforces budgets, and triggers wake on completion.

**Files to create**:
- `lib/loomkin/healing/orchestrator.ex` — GenServer managing active healing sessions
- `lib/loomkin/healing/session.ex` — Data structure for an individual healing session

### Healing Session

```elixir
defmodule Loomkin.Healing.Session do
  defstruct [
    :id,                    # UUID
    :team_id,               # Team the suspended agent belongs to
    :agent_name,            # Name of the suspended agent
    :classification,        # ErrorClassifier result
    :error_context,         # Raw error text, tool name, args
    :status,                # :diagnosing | :fixing | :confirming | :complete | :failed | :timed_out
    :diagnosis,             # Diagnostician's report (populated after diagnosis)
    :fix_result,            # Fixer's result (populated after fix)
    :diagnostician_id,      # Team ID of diagnostician sub-agent
    :fixer_id,              # Team ID of fixer sub-agent
    :started_at,            # DateTime
    :budget_remaining_usd,  # Cost ceiling for this healing session
    :max_iterations,        # Iteration cap across both agents
    :attempts,              # Number of fix attempts (for retry logic)
    :max_attempts           # Maximum fix attempts before escalation
  ]
end
```

### Orchestrator GenServer

```elixir
defmodule Loomkin.Healing.Orchestrator do
  use GenServer

  @default_budget_usd 0.50
  @default_max_iterations 15
  @default_max_attempts 2
  @default_timeout_ms :timer.minutes(5)

  # --- Public API ---

  @doc "Request healing for a suspended agent"
  @spec request_healing(String.t(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def request_healing(team_id, agent_name, healing_context)

  @doc "Receive diagnosis report from diagnostician agent"
  @spec report_diagnosis(String.t(), map()) :: :ok
  def report_diagnosis(session_id, diagnosis)

  @doc "Receive fix confirmation from fixer agent"
  @spec confirm_fix(String.t(), map()) :: :ok
  def confirm_fix(session_id, fix_result)

  @doc "Cancel an active healing session (manual intervention)"
  @spec cancel_healing(String.t()) :: :ok | {:error, :not_found}
  def cancel_healing(session_id)

  @doc "Get status of active healing sessions for a team"
  @spec active_sessions(String.t()) :: [Session.t()]
  def active_sessions(team_id)
end
```

### Orchestration Flow

```elixir
# 1. Receive healing request
def handle_cast({:request_healing, team_id, agent_name, context}, state) do
  session = %Session{
    id: Loomkin.ID.generate(),
    team_id: team_id,
    agent_name: agent_name,
    classification: context.classification,
    error_context: context,
    status: :diagnosing,
    started_at: DateTime.utc_now(),
    budget_remaining_usd: @default_budget_usd,
    max_iterations: @default_max_iterations,
    attempts: 0,
    max_attempts: @default_max_attempts
  }

  # Spawn diagnostician as ephemeral sub-agent
  {:ok, diag_id} = spawn_diagnostician(session)
  session = %{session | diagnostician_id: diag_id}

  # Set timeout
  timer_ref = Process.send_after(self(), {:healing_timeout, session.id}, @default_timeout_ms)

  state = put_session(state, session, timer_ref)
  {:noreply, state}
end

# 2. Diagnosis received → spawn fixer
def handle_cast({:diagnosis_received, session_id, diagnosis}, state) do
  session = get_session(state, session_id)
  session = %{session | diagnosis: diagnosis, status: :fixing, attempts: session.attempts + 1}

  # Spawn fixer with diagnosis context
  {:ok, fixer_id} = spawn_fixer(session)
  session = %{session | fixer_id: fixer_id}

  state = put_session(state, session, nil)
  {:noreply, state}
end

# 3. Fix confirmed → wake original agent
def handle_cast({:fix_confirmed, session_id, fix_result}, state) do
  session = get_session(state, session_id)
  session = %{session | fix_result: fix_result, status: :complete}

  # Build summary for the original agent
  summary = %{
    description: "Self-healing completed",
    root_cause: session.diagnosis.root_cause,
    fix_description: fix_result.description,
    files_changed: fix_result.files_changed
  }

  # Wake the original agent
  Loomkin.Teams.Agent.wake_from_healing(
    session.team_id,
    session.agent_name,
    summary
  )

  # Clean up ephemeral agents
  cleanup_healing_agents(session)

  state = remove_session(state, session_id)
  {:noreply, state}
end

# 4. Fix failed → retry or escalate
def handle_cast({:fix_failed, session_id, reason}, state) do
  session = get_session(state, session_id)

  if session.attempts < session.max_attempts do
    # Retry: re-diagnose with additional context about the failed fix
    session = %{session | status: :diagnosing}
    {:ok, diag_id} = spawn_diagnostician(session, retry_context: reason)
    state = put_session(state, %{session | diagnostician_id: diag_id}, nil)
    {:noreply, state}
  else
    # Escalate: notify lead agent or user
    escalate(session, reason)
    wake_with_failure(session, reason)
    state = remove_session(state, session_id)
    {:noreply, state}
  end
end

# 5. Timeout → escalate
def handle_info({:healing_timeout, session_id}, state) do
  case get_session(state, session_id) do
    nil -> {:noreply, state}
    session ->
      session = %{session | status: :timed_out}
      escalate(session, :timeout)
      wake_with_failure(session, "Healing timed out after #{@default_timeout_ms}ms")
      state = remove_session(state, session_id)
      {:noreply, state}
  end
end
```

### Spawning Ephemeral Agents

Diagnostician and fixer agents are spawned as lightweight sub-agents (similar to `SubAgent` tool), not as full team members:

```elixir
defp spawn_diagnostician(session, opts \\ []) do
  task_description = build_diagnosis_task(session, opts)

  Loomkin.Healing.EphemeralAgent.start(
    role: :diagnostician,
    team_id: session.team_id,
    session_id: session.id,
    task: task_description,
    tools: diagnostician_tools(),
    max_iterations: div(session.max_iterations, 2),
    budget_usd: session.budget_remaining_usd * 0.4,
    on_complete: &Orchestrator.report_diagnosis(session.id, &1)
  )
end

defp spawn_fixer(session) do
  task_description = build_fix_task(session)

  Loomkin.Healing.EphemeralAgent.start(
    role: :fixer,
    team_id: session.team_id,
    session_id: session.id,
    task: task_description,
    diagnosis: session.diagnosis,
    tools: fixer_tools(),
    max_iterations: div(session.max_iterations, 2),
    budget_usd: session.budget_remaining_usd * 0.6,
    on_complete: &Orchestrator.confirm_fix(session.id, &1)
  )
end
```

**Acceptance Criteria**:
- [ ] `request_healing/3` creates a session and spawns a diagnostician agent
- [ ] `report_diagnosis/2` transitions session to `:fixing` and spawns a fixer agent
- [ ] `confirm_fix/2` wakes the original agent with a summary and cleans up ephemeral agents
- [ ] Failed fixes retry up to `max_attempts` before escalating
- [ ] Healing sessions time out after configurable duration (default: 5 minutes)
- [ ] Timed-out sessions wake the original agent with a failure summary
- [ ] Budget tracking prevents healing from exceeding cost ceiling
- [ ] `active_sessions/1` returns all in-progress healing sessions for a team
- [ ] `cancel_healing/1` terminates a healing session and wakes the agent
- [ ] Concurrent healing sessions for different agents in the same team don't interfere

---

## 14.4: Ephemeral Healing Agents

**Complexity**: Medium
**Dependencies**: 14.3
**Description**: Lightweight, short-lived agents purpose-built for diagnosis and repair. They reuse the existing `AgentLoop` but with constrained tool sets, tight iteration limits, and structured output requirements.

**Files to create**:
- `lib/loomkin/healing/ephemeral_agent.ex` — Starts and manages short-lived healing agents
- `lib/loomkin/healing/prompts.ex` — System prompts for diagnostician and fixer roles

### Ephemeral Agent

Unlike full team agents (which are GenServers registered in the team), ephemeral agents are simple `Task.Supervisor` processes that run an `AgentLoop` and report back:

```elixir
defmodule Loomkin.Healing.EphemeralAgent do
  @doc "Start an ephemeral healing agent under the task supervisor"
  def start(opts) do
    Task.Supervisor.async_nolink(Loomkin.TaskSupervisor, fn ->
      run(opts)
    end)
  end

  defp run(opts) do
    config = %{
      system_prompt: build_prompt(opts[:role], opts),
      tools: opts[:tools],
      model: healing_model(opts[:team_id]),
      max_iterations: opts[:max_iterations],
      budget_usd: opts[:budget_usd],
      session_id: opts[:session_id],
      team_id: opts[:team_id],
      agent_name: ephemeral_name(opts[:role], opts[:session_id]),
      on_event: &handle_event/2
    }

    messages = [%{role: :user, content: opts[:task]}]

    case AgentLoop.run(messages, config) do
      {:ok, result} -> opts[:on_complete].(parse_result(opts[:role], result))
      {:error, reason} -> opts[:on_error].(reason)
    end
  end
end
```

### Diagnostician Role

**Tools available**: `LspDiagnostics`, `FileRead`, `ContentSearch`, `FileSearch`, `DirectoryList`, `Shell` (read-only commands only), `DiagnosisReport`

**System prompt structure**:
```
You are a Diagnostician agent. Your job is to analyze an error that occurred
during another agent's work and identify the root cause.

ERROR CONTEXT:
- Error category: {category}
- Error text: {error_text}
- Tool that failed: {tool_name}
- File context: {file_path}
- Agent role: {agent_role}
- Agent task: {agent_task_description}

YOUR OBJECTIVE:
1. Read the relevant files and diagnostics to understand the error
2. Identify the root cause (not just the symptom)
3. Determine what needs to change to fix it
4. Submit a structured diagnosis report using the diagnosis_report tool

CONSTRAINTS:
- You are READ-ONLY. Do not modify any files
- Focus on root cause, not symptoms
- Be specific: name exact files, line numbers, and the fix needed
- You have {max_iterations} iterations maximum
```

### Fixer Role

**Tools available**: `FileRead`, `FileEdit`, `FileWrite`, `Shell`, `Git`, `LspDiagnostics`, `FixConfirmation`

**System prompt structure**:
```
You are a Fixer agent. A Diagnostician has identified a problem and you need
to apply a targeted fix.

DIAGNOSIS:
- Root cause: {root_cause}
- Affected files: {affected_files}
- Suggested fix: {suggested_fix}
- Original error: {error_text}

YOUR OBJECTIVE:
1. Apply the fix as described in the diagnosis
2. Verify the fix works (run relevant commands, check diagnostics)
3. Submit a fix confirmation using the fix_confirmation tool

CONSTRAINTS:
- Make the MINIMAL change needed to resolve the issue
- Do not refactor, clean up, or improve surrounding code
- Verify your fix doesn't introduce new errors
- You have {max_iterations} iterations maximum
```

### Model Selection

Healing agents use a fast/cheap model by default since their tasks are focused and constrained:

```elixir
defp healing_model(team_id) do
  # Use the team's configured fast model (same as sub-agents)
  case Loomkin.Teams.Manager.get_meta(team_id) do
    %{fast_model: model} when not is_nil(model) -> model
    _ -> "anthropic:claude-sonnet-4-6"
  end
end
```

**Acceptance Criteria**:
- [ ] Ephemeral agents run under `Task.Supervisor` with proper cleanup on crash
- [ ] Diagnostician agent has read-only tools (no file modification)
- [ ] Fixer agent has write-capable tools
- [ ] System prompts include full error context and diagnosis context
- [ ] Ephemeral agents respect iteration and budget limits
- [ ] `on_complete` callback fires with structured result on success
- [ ] `on_error` callback fires on agent failure or budget exhaustion
- [ ] Ephemeral agent events are published to the team's PubSub topic
- [ ] Healing agents use the team's fast model by default

---

## 14.5: Healing Tools

**Complexity**: Small
**Dependencies**: 14.3, 14.4
**Description**: Two new Jido.Action tools that diagnostician and fixer agents use to submit their structured results back to the HealingOrchestrator.

**Files to create**:
- `lib/loomkin/tools/diagnosis_report.ex` — Tool for diagnostician to submit structured findings
- `lib/loomkin/tools/fix_confirmation.ex` — Tool for fixer to confirm repair and report changes

### DiagnosisReport Tool

```elixir
defmodule Loomkin.Tools.DiagnosisReport do
  use Jido.Action,
    name: "diagnosis_report",
    description: """
    Submit a structured diagnosis report identifying the root cause of an error.
    This is the final action of a diagnostician agent.
    """,
    schema: [
      session_id: [type: :string, required: true, doc: "The healing session ID"],
      root_cause: [type: :string, required: true, doc: "Clear description of the root cause"],
      affected_files: [type: {:list, :string}, required: true, doc: "List of file paths involved"],
      suggested_fix: [type: :string, required: true, doc: "Specific fix instructions for the fixer agent"],
      severity: [type: {:in, [:low, :medium, :high, :critical]}, required: true, doc: "Assessed severity"],
      confidence: [type: :float, required: true, doc: "Confidence in diagnosis (0.0 to 1.0)"]
    ]

  @impl true
  def run(params, _context) do
    diagnosis = %{
      root_cause: params.root_cause,
      affected_files: params.affected_files,
      suggested_fix: params.suggested_fix,
      severity: params.severity,
      confidence: params.confidence
    }

    Loomkin.Healing.Orchestrator.report_diagnosis(params.session_id, diagnosis)

    {:ok, %{result: "Diagnosis submitted. Fixer agent will be spawned to apply the fix."}}
  end
end
```

### FixConfirmation Tool

```elixir
defmodule Loomkin.Tools.FixConfirmation do
  use Jido.Action,
    name: "fix_confirmation",
    description: """
    Confirm that a fix has been applied and verified.
    This is the final action of a fixer agent.
    """,
    schema: [
      session_id: [type: :string, required: true, doc: "The healing session ID"],
      description: [type: :string, required: true, doc: "What was changed and why"],
      files_changed: [type: {:list, :string}, required: true, doc: "List of modified file paths"],
      verified: [type: :boolean, required: true, doc: "Whether the fix was verified (e.g., tests pass, no diagnostics)"],
      verification_output: [type: :string, doc: "Output from verification step (test results, diagnostic check)"]
    ]

  @impl true
  def run(params, _context) do
    if params.verified do
      fix_result = %{
        description: params.description,
        files_changed: params.files_changed,
        verification_output: params.verification_output
      }

      Loomkin.Healing.Orchestrator.confirm_fix(params.session_id, fix_result)
      {:ok, %{result: "Fix confirmed. Original agent will be woken up."}}
    else
      Loomkin.Healing.Orchestrator.fix_failed(params.session_id, params.description)
      {:ok, %{result: "Fix not verified. Orchestrator will decide whether to retry."}}
    end
  end
end
```

**Acceptance Criteria**:
- [ ] `DiagnosisReport` validates all required fields before submitting
- [ ] `DiagnosisReport` calls `Orchestrator.report_diagnosis/2` with structured data
- [ ] `FixConfirmation` with `verified: true` triggers `Orchestrator.confirm_fix/2`
- [ ] `FixConfirmation` with `verified: false` triggers `Orchestrator.fix_failed/2`
- [ ] Both tools are registered in the tool registry
- [ ] Tools include descriptive error messages for missing/invalid params
- [ ] `confidence` field on diagnosis is bounded between 0.0 and 1.0

---

## 14.6: Role Configuration & Healing Policy

**Complexity**: Small
**Dependencies**: 14.1
**Description**: Extend the existing role configuration system to include healing policy — which roles auto-heal, what error categories trigger healing per role, and healing budget allocation.

**Files to modify**:
- `lib/loomkin/teams/role.ex` (or equivalent role config module) — Add healing policy fields
- `lib/loomkin/healing/error_classifier.ex` — Respect role-specific healing policies

### Role Healing Policy

```elixir
# Added to the role config struct
defstruct [
  # ... existing fields ...
  healing_policy: %{
    enabled: true,                    # Whether this role auto-heals
    categories: [:compile_error, :lint_error, :command_failure, :test_failure, :tool_error],
    min_severity: :medium,            # Minimum severity to trigger healing
    failure_threshold: 1,             # Consecutive failures before healing triggers
    budget_usd: 0.50,                 # Per-session healing budget
    max_attempts: 2,                  # Max fix attempts before escalation
    timeout_ms: :timer.minutes(5)     # Healing session timeout
  }
]
```

### Default Policies by Role

| Role | Auto-Heal | Categories | Failure Threshold | Notes |
|------|-----------|------------|-------------------|-------|
| `:coder` | Yes | All healable | 1 | Most likely to benefit from healing |
| `:tester` | Yes | compile, command, test | 1 | Test failures are the primary trigger |
| `:researcher` | Yes | command, tool | 2 | Less likely to hit code errors |
| `:reviewer` | No | — | — | Read-only role, errors are informational |
| `:lead` | No | — | — | Strategic role, should handle errors via delegation |
| `:weaver` | No | — | — | Summary role, rarely encounters fixable errors |
| Custom | Yes | compile, lint, command | 2 | Conservative defaults for custom roles |

**Acceptance Criteria**:
- [ ] Role config struct includes `healing_policy` with all documented fields
- [ ] Default policies are defined for all built-in roles
- [ ] Custom roles receive conservative default healing policies
- [ ] `ErrorClassifier.should_heal?/2` reads the agent's role healing policy
- [ ] Healing can be disabled per-role by setting `enabled: false`
- [ ] Healing categories can be customized per-role

---

## 14.7: Healing Signals & Workspace Visibility

**Complexity**: Medium
**Dependencies**: 14.2, 14.3
**Description**: Make healing activity visible in the workspace UI. Agent cards show suspension status, a healing indicator shows progress, and the comms feed displays healing events.

**Files to create**:
- `lib/loomkin/signals/healing.ex` — Signal types for healing lifecycle events

**Files to modify**:
- `lib/loomkin_web/live/workspace_live.ex` — Handle healing signals, update agent card state
- `lib/loomkin_web/live/agent_card_component.ex` — Render suspension and healing status

### Healing Signal Types

```elixir
defmodule Loomkin.Signals.Healing do
  defmodule SessionStarted do
    use Jido.Signal,
      type: "healing.session.started",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        classification: [type: :map, required: true]
      ]
  end

  defmodule DiagnosisComplete do
    use Jido.Signal,
      type: "healing.diagnosis.complete",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        root_cause: [type: :string, required: true],
        confidence: [type: :float, required: true]
      ]
  end

  defmodule FixApplied do
    use Jido.Signal,
      type: "healing.fix.applied",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        files_changed: [type: {:list, :string}, required: true]
      ]
  end

  defmodule SessionComplete do
    use Jido.Signal,
      type: "healing.session.complete",
      schema: [
        session_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true],
        outcome: [type: {:in, [:healed, :escalated, :timed_out]}, required: true],
        duration_ms: [type: :integer, required: true]
      ]
  end
end
```

### Agent Card — Suspended State

When an agent is in `:suspended_healing` status, the agent card shows:

- Status badge changes to amber/yellow with a pulse animation: "Healing..."
- A compact healing progress indicator below the status:
  - Phase 1: "Diagnosing..." (with diagnostician activity)
  - Phase 2: "Applying fix..." (with fixer activity)
  - Phase 3: "Verifying..." (fixer running verification)
- The agent's previous task context remains visible (not replaced)
- A subtle "suspended" overlay that conveys the agent is paused, not crashed

### Comms Feed Events

| Event | Icon | Color | Display |
|---|---|---|---|
| `healing.session.started` | wrench | amber | "{agent} suspended for healing: {category}" |
| `healing.diagnosis.complete` | magnifying glass | blue | "Diagnosis: {root_cause} (confidence: {n}%)" |
| `healing.fix.applied` | check-circle | green | "Fix applied to {n} file(s): {files}" |
| `healing.session.complete` | sparkles | green/red | "Healing {outcome}: {agent} resumed" / "Healing failed: escalated" |

**Acceptance Criteria**:
- [ ] All four healing signal types are defined and publishable
- [ ] WorkspaceLive handles healing signals and updates agent card state
- [ ] Agent card renders `:suspended_healing` status with healing phase indicator
- [ ] Comms feed displays healing events with appropriate formatting
- [ ] Healing progress updates in real-time as phases transition
- [ ] Completed healing transitions agent card back to normal status
- [ ] Failed/timed-out healing shows escalation state in agent card
- [ ] Healing events appear in the team activity component

---

## 14.8: Testing & Edge Cases

**Complexity**: Medium
**Dependencies**: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6, 14.7
**Description**: Comprehensive test coverage for the self-healing system, including unit tests for each module, integration tests for the full healing lifecycle, and edge case handling.

**Files to create**:
- `test/loomkin/healing/error_classifier_test.exs`
- `test/loomkin/healing/orchestrator_test.exs`
- `test/loomkin/healing/ephemeral_agent_test.exs`
- `test/loomkin/healing/session_test.exs`
- `test/loomkin/tools/diagnosis_report_test.exs`
- `test/loomkin/tools/fix_confirmation_test.exs`
- `test/loomkin/healing/integration_test.exs`

### Key Test Scenarios

**Error Classification:**
- Each error category with representative error text
- Edge cases: multi-line errors, mixed categories, empty error text
- `should_heal?` respects failure thresholds and role policies

**Orchestrator Lifecycle:**
- Happy path: request → diagnose → fix → wake
- Retry path: request → diagnose → fix fails → re-diagnose → fix → wake
- Timeout path: request → diagnose → timeout → escalation → wake with failure
- Budget exhaustion: healing exceeds cost ceiling → escalation
- Concurrent sessions: two agents in same team healing simultaneously
- Cancel: manual cancellation mid-healing

**Agent Suspension:**
- Agent suspends and freezes state correctly
- Suspended agent rejects new tasks (queues them)
- Wake restores state and injects summary
- Wake re-runs agent loop successfully
- Double-wake is a no-op (idempotent)

**Ephemeral Agents:**
- Diagnostician produces structured diagnosis report
- Fixer applies fix and runs verification
- Agent cleanup on success and failure
- Budget/iteration limits enforced

**Edge Cases:**
- Agent crashes while suspended → watcher detects, orchestrator cancels session
- Diagnostician crashes → orchestrator retries or escalates
- Fixer introduces a new error → detected, retry with expanded context
- Healing requested for already-healing agent → rejected (one session per agent)
- Team dissolved while healing in progress → cleanup all sessions

**Acceptance Criteria**:
- [ ] Error classifier has at least 20 test cases across all categories
- [ ] Orchestrator lifecycle tests cover happy path, retry, timeout, and cancellation
- [ ] Integration test runs full healing cycle with mocked LLM responses
- [ ] Concurrent healing sessions are tested for isolation
- [ ] Edge cases (crash during healing, double-wake, team dissolution) are covered
- [ ] All healing modules have at least 90% code coverage
- [ ] Tests use `start_supervised!` for all process management
- [ ] No `Process.sleep` in tests — use monitors and `assert_receive`

---

## Implementation Order

```
14.1 Error Classification ──> 14.2 Suspension & Wake ──> 14.3 Orchestrator ──┐
                                                                              │
14.6 Role Config ─────────────────────────────────────────────────────────────┤
                                                                              │
                              14.4 Ephemeral Agents ──> 14.5 Healing Tools ──┤
                                                                              │
                                                        14.7 Signals & UI ───┤
                                                                              │
                                                        14.8 Testing ────────┘
```

**Recommended order**:
1. **14.1** Error classification (foundation — everything depends on knowing what's healable)
2. **14.6** Role configuration (small, defines policies that 14.1 reads)
3. **14.2** Agent suspension & wake (core primitive — agents need to suspend before orchestration)
4. **14.3** Healing orchestrator (central coordinator, depends on 14.1 + 14.2)
5. **14.4** Ephemeral healing agents (workers the orchestrator spawns)
6. **14.5** Healing tools (small, tools ephemeral agents use to report results)
7. **14.7** Signals & UI (visibility layer, can be developed in parallel with 14.4-14.5)
8. **14.8** Testing (throughout, but final coverage pass here)

**Phase gate**: After 14.5, the self-healing system is functionally complete. An agent can suspend, be diagnosed, be fixed, and resume. 14.7 adds visibility, and 14.8 hardens the system. This is a good milestone for validation with a real agent team.

## Risks & Open Questions

1. **Healing loops**: What if the fixer's changes cause a new error that triggers another healing session? Mitigation: track `healing_depth` per agent — if an agent has been healed N times for the same task, escalate instead. Default max: 2 healing sessions per task

2. **Context window pressure**: The diagnostician receives the original agent's error context plus its own conversation. For large codebases with verbose errors, this could be expensive. Mitigation: the error context is summarized before injection, not passed raw. The `classification.error_context` is capped at a reasonable size

3. **Model quality for healing**: Healing agents use the fast/cheap model by default. For subtle bugs (race conditions, type mismatches), a stronger model may be needed. Mitigation: if the first healing attempt fails, the retry can escalate to the thinking model

4. **Interaction with speculative execution (6.5)**: If a speculative agent hits an error, should it heal or just discard? Probably discard — speculative work is tentative by nature. The healing policy should respect speculative status

5. **Concurrent file edits**: The fixer agent modifies files while the original agent is suspended. If other agents are also editing the same files, conflicts can occur. Mitigation: the fixer's scope is limited to files identified in the diagnosis. For shared files, the fixer should use `file_edit` (not `file_write`) to minimize conflict surface

6. **Healing observability**: Users need to understand why an agent suspended and what happened during healing. The comms feed events (14.7) address this, but a dedicated "healing history" view might be valuable in the future

7. **Pre-existing checkpoint system (6.3)**: If 6.3 is complete, suspension can leverage its pause/resume primitive directly. If 6.3 is not complete, 14.2 needs to implement a simpler suspension mechanism. The design above is compatible with both approaches — the `frozen_state` pattern works independently of checkpoints
