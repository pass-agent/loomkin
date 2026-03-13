# Epic 13: Conversation Agents — Freeform Multi-Agent Dialogue

## Problem Statement

Loomkin agents are built for task-oriented coordination: delegate work, report results, negotiate assignments. All 20+ peer communication tools are structured around task lifecycle. Agents have isolated message histories, react only when explicitly addressed, and cannot participate in freeform group dialogue.

This means agents can't do things like:
- Brainstorm an approach together before starting work
- Roleplay as domain experts debating a design decision
- Simulate user personas discussing a feature
- Hold a retrospective on completed work
- Explore a problem space through open-ended conversation

These are all forms of **deliberation** — collaborative thinking that produces insight, not artifacts. Today's task agents are optimized for producing artifacts. Conversation agents are optimized for producing understanding.

## Why a New Agent Type

Adding conversation capabilities to existing task agents would cause severe context/token bloat:

| Concern | Task Agent Impact |
|---|---|
| Tool definitions | 20+ task tools already consume ~10-15k tokens of context; adding conversation tools would push further |
| Message history | Shared conversation stream (N agents x M rounds) would flood the context window meant for code and tool results |
| System prompt | Task-oriented prompt guidance would conflict with dialogue-oriented behavior |
| LLM call pattern | Task agents make few, expensive calls with dense technical context; conversation agents need many small, fast calls |
| Loop behavior | Task agents are reactive (idle until prompted); conversation agents must self-initiate speech |

Conversation agents are a fundamentally different execution mode. They should be cheap, fast, and context-light so task agents can spawn them as a "deliberation service" without paying the cost themselves.

## Architecture

```
Task Agent (existing)
  |
  +-- spawns conversation group via tool
  |
  v
ConversationServer (new GenServer, per conversation)
  |
  +-- manages shared history, turn order, round tracking
  |
  +-- ConversationAgent 1 (lightweight agent, persona-driven)
  +-- ConversationAgent 2
  +-- ConversationAgent 3
  |
  +-- ConversationWeaver (auto-spawned summarizer)
  |
  v
Summary returned to spawning task agent (or broadcast to team)
```

### Key Design Decisions

1. **ConversationServer owns the shared history.** Unlike task agents (isolated message histories), conversation agents all read from and write to a single ordered message log managed by the ConversationServer. This is the core architectural difference.

2. **Turn-based, not free-for-all.** The ConversationServer controls who speaks next. This prevents collision, controls costs, and produces coherent dialogue. Multiple turn strategies supported (round-robin, weighted, facilitator-directed).

3. **Minimal tool set.** Conversation agents get ~3-5 tools (speak, react, yield, end_conversation) instead of 20+. This maximizes context budget for dialogue history.

4. **Conversation-scoped weaver.** A lightweight summarizer agent watches the conversation and produces a distilled summary when it ends. This summary is what gets returned to the spawning task agent — not the full transcript.

5. **Task agents spawn conversations as a service.** A task agent hitting a design decision can spawn a conversation group, wait for the summary, and proceed with a single compact context injection. The task agent never sees the full back-and-forth.

6. **Fast model by default.** Conversation agents should use the session's fast model (e.g., Haiku/Sonnet) since they're making many small calls. The spawning task agent can override this.

7. **Budget-capped.** Each conversation has a max round count and token budget. Conversations auto-terminate when either limit is hit.

## Dependencies

**No new deps required.** This builds entirely on existing infrastructure:
- Jido Signal Bus (message delivery)
- Agent GenServer patterns (from `agent.ex`)
- Signal types (extend `collaboration.ex`)
- TeamBroadcaster (UI updates)
- Comms feed (already renders 25+ event types)

---

## 13.1: ConversationServer — Shared History & Turn Management

**Complexity**: Large
**Dependencies**: None
**Description**: A GenServer that manages a single conversation session — shared message history, turn order, round tracking, and termination conditions.

**Files to create**:
- `lib/loomkin/conversations/server.ex`
- `lib/loomkin/conversations/turn_strategy.ex`

**ConversationServer state**:
```elixir
defmodule Loomkin.Conversations.Server do
  use GenServer

  defstruct [
    :id,                    # Unique conversation ID
    :team_id,               # Parent team (for signal routing)
    :topic,                 # What the conversation is about
    :spawned_by,            # Agent name that initiated the conversation
    :turn_strategy,         # :round_robin | :weighted | :facilitator
    :participants,          # [{name, persona, role_in_conversation}]
    :history,               # Ordered list of %{speaker: name, content: text, round: n}
    :current_round,         # Integer
    :current_speaker,       # Name of agent whose turn it is
    :max_rounds,            # Hard cap (default: 10)
    :max_tokens,            # Budget cap for entire conversation
    :tokens_used,           # Running total
    :status,                # :active | :summarizing | :completed | :terminated
    :summary,               # Populated by weaver when conversation ends
    :started_at,
    :ended_at
  ]
end
```

**Turn strategies**:
```elixir
defmodule Loomkin.Conversations.TurnStrategy do
  @callback next_speaker(participants, history, current_round) :: participant_name
  @callback should_advance_round?(participants, history, current_round) :: boolean()
end
```

- **Round-robin**: Each participant speaks once per round, fixed order.
- **Weighted**: Participants who haven't spoken recently get priority. Participants can yield their turn.
- **Facilitator**: One participant is designated facilitator and calls on others. Good for structured debates.

**Server API**:
```elixir
# Start a conversation
ConversationServer.start_link(opts)

# Agent submits their speech for their turn
ConversationServer.speak(conversation_id, agent_name, content)

# Agent yields their turn (nothing to add)
ConversationServer.yield(conversation_id, agent_name)

# Get current state (for prompting the next speaker)
ConversationServer.get_context(conversation_id)

# Force-end the conversation
ConversationServer.terminate(conversation_id, reason)
```

**Turn flow**:
```
1. Server determines next speaker via turn_strategy
2. Server sends signal to that agent: {:your_turn, conversation_id, history, topic}
3. Agent generates response via LLM call (sees full shared history)
4. Agent calls speak(conversation_id, name, content)
5. Server appends to history, checks termination conditions
6. If not done: goto 1
7. If done: transition to :summarizing, signal weaver
```

**Termination conditions** (any triggers end):
- `current_round > max_rounds`
- `tokens_used > max_tokens`
- All participants yield in the same round (consensus to stop)
- Facilitator calls end_conversation
- Spawning agent cancels the conversation
- Inactivity timeout (no speech for 60 seconds)

**Signals emitted**:
- `conversation.started` — topic, participants, strategy
- `conversation.turn` — speaker, content, round number
- `conversation.round_complete` — round number, summary of round
- `conversation.yield` — agent yielded their turn
- `conversation.ended` — reason, round count, summary (when available)

**Acceptance Criteria**:
- [ ] ConversationServer manages shared history correctly
- [ ] Round-robin turn strategy cycles through all participants
- [ ] Weighted strategy prioritizes quiet participants
- [ ] Facilitator strategy respects facilitator's direction
- [ ] Max rounds and max tokens caps enforce termination
- [ ] All-yield detection ends conversation
- [ ] Inactivity timeout prevents hung conversations
- [ ] Signals emitted for all lifecycle events

---

## 13.2: ConversationAgent — Lightweight Dialogue Agent

**Complexity**: Medium
**Dependencies**: 13.1
**Description**: A stripped-down agent type optimized for conversation. Minimal tools, persona-driven system prompt, reads from shared history instead of isolated messages.

**Files to create**:
- `lib/loomkin/conversations/agent.ex`
- `lib/loomkin/conversations/persona.ex`

**Key differences from task agents**:

| Aspect | Task Agent (`teams/agent.ex`) | Conversation Agent |
|---|---|---|
| Message history | Isolated, private | Shared via ConversationServer |
| Tool count | 20+ | 3-5 |
| System prompt | Role + task guidance | Persona + conversation context |
| Loop trigger | External (message/task) | ConversationServer turn signal |
| LLM model | Session thinking model | Session fast model (default) |
| Lifecycle | Long-lived (entire session) | Short-lived (one conversation) |

**Conversation tools** (the only tools available):
```elixir
# speak — submit your dialogue contribution
speak(content: "I think we should consider...")

# react — short reaction without taking a full turn (emoji, agreement, etc.)
react(type: :agree | :disagree | :question | :laugh | :think, brief: "Good point about X")

# yield — pass your turn (nothing to add right now)
yield(reason: "I'll wait to hear from others first")

# end_conversation — propose ending the conversation (facilitator only, or requires majority)
end_conversation(reason: "I think we've reached consensus")
```

**Persona struct**:
```elixir
defmodule Loomkin.Conversations.Persona do
  defstruct [
    :name,           # Display name in conversation
    :description,    # One-line description
    :perspective,    # What viewpoint they bring
    :personality,    # Communication style guidance
    :expertise,      # Domain knowledge areas
    :goal            # What they're trying to achieve in this conversation
  ]
end
```

**System prompt template**:
```
You are {name}, {description}.

## Your Perspective
{perspective}

## Your Personality
{personality}

## Your Expertise
{expertise}

## Conversation Topic
{topic}

## Your Goal
{goal}

## Guidelines
- Stay in character. Speak naturally as {name} would.
- Build on what others have said. Reference their points by name.
- Be concise. This is a conversation, not an essay. 2-4 sentences is ideal.
- If you have nothing meaningful to add, use the yield tool.
- Disagree constructively when you genuinely see it differently.
- Ask questions when you need clarity from a specific participant.
```

**Turn handling**:
```elixir
def handle_info({:your_turn, conversation_id, history, topic}, state) do
  # Build messages from shared history
  messages = build_conversation_messages(history, state.persona)

  # Single LLM call with conversation context
  {:ok, response} = LLM.chat(state.model, messages, tools: @conversation_tools)

  # Execute tool call (speak, react, or yield)
  execute_conversation_tool(response, conversation_id, state)

  {:noreply, state}
end
```

**Acceptance Criteria**:
- [ ] Conversation agents use fast model by default
- [ ] System prompt correctly interpolates persona fields
- [ ] Agents see full shared history when generating responses
- [ ] speak/react/yield tools work correctly with ConversationServer
- [ ] Agents are short-lived — clean up after conversation ends
- [ ] Token usage is tracked per-agent and reported to ConversationServer

---

## 13.3: Conversation Weaver — Auto-Summarization

**Complexity**: Small
**Dependencies**: 13.1, 13.2
**Description**: A specialized conversation agent that watches the dialogue and produces a structured summary when it ends. This summary is what gets returned to the spawning task agent.

**Files to create**:
- `lib/loomkin/conversations/weaver.ex`

**Weaver behavior**:
- Does NOT participate in turns (observer only)
- Receives all `conversation.turn` signals
- When conversation transitions to `:summarizing`, generates summary
- Summary includes: key points, areas of agreement, areas of disagreement, open questions, recommended actions

**Summary format**:
```elixir
%{
  topic: "Authentication approach for the new API",
  rounds: 7,
  participants: ["Security Expert", "API Designer", "DevOps Lead"],
  key_points: [
    "OAuth2 preferred over API keys for user-facing endpoints",
    "Rate limiting should be per-token, not per-IP",
    "JWT refresh tokens need a rotation strategy"
  ],
  consensus: [
    "OAuth2 with PKCE for the public API",
    "API keys acceptable for server-to-server only"
  ],
  disagreements: [
    "Token expiry duration: 15min vs 1hr (Security Expert vs API Designer)"
  ],
  open_questions: [
    "How to handle token revocation at scale?"
  ],
  recommended_actions: [
    "Implement OAuth2 with PKCE as primary auth",
    "Research token revocation approaches before deciding"
  ]
}
```

**Acceptance Criteria**:
- [ ] Weaver auto-spawns with every conversation
- [ ] Summary captures key points, consensus, and disagreements
- [ ] Summary is structured (not just prose) for programmatic use
- [ ] Summary is attached to ConversationServer state on completion
- [ ] Spawning task agent receives summary via signal or return value

---

## 13.4: Spawn Conversation Tool — Task Agent Integration

**Complexity**: Medium
**Dependencies**: 13.1, 13.2, 13.3
**Description**: A tool available to task agents that lets them spawn a conversation group. The task agent defines the topic, personas, and constraints. The conversation runs asynchronously and returns a summary.

**Files to create**:
- `lib/loomkin/tools/spawn_conversation.ex`

**Tool definition**:
```elixir
defmodule Loomkin.Tools.SpawnConversation do
  use Jido.Action,
    name: "spawn_conversation",
    description: """
    Spawn a group of conversation agents to discuss a topic and return a summary.
    Useful for: brainstorming, design deliberation, perspective gathering, red-teaming.
    The conversation runs asynchronously. You'll receive a summary when it completes.
    """,
    schema: [
      topic: [type: :string, required: true,
        doc: "What the agents should discuss"],
      personas: [type: {:list, :map}, required: true,
        doc: "List of personas. Each needs: name, perspective, expertise. Min 2, max 6."],
      strategy: [type: :string, default: "round_robin",
        doc: "Turn strategy: round_robin, weighted, or facilitator"],
      max_rounds: [type: :integer, default: 8,
        doc: "Maximum conversation rounds (default: 8)"],
      facilitator: [type: :string,
        doc: "Name of the facilitator persona (required if strategy is 'facilitator')"],
      context: [type: :string,
        doc: "Additional context to provide all participants (code snippets, requirements, etc.)"]
    ]
end
```

**Usage by task agents**:
```
# Task agent hits a design decision
spawn_conversation(
  topic: "Should we use GenServer or Agent for the cache layer?",
  personas: [
    %{name: "Systems Architect", perspective: "Favors explicit state management and supervision", expertise: "OTP design patterns"},
    %{name: "Pragmatist", perspective: "Favors simplicity and fewer moving parts", expertise: "Production Elixir systems"},
    %{name: "Performance Engineer", perspective: "Focused on throughput and latency", expertise: "BEAM VM internals, ETS, benchmarking"}
  ],
  max_rounds: 6,
  context: "The cache needs to store ~10k entries, handle 1000 reads/sec, and support TTL expiry."
)
```

**Return flow**:
1. Tool validates personas (2-6 participants)
2. Starts ConversationServer with topic, personas, strategy
3. Spawns ConversationAgents for each persona
4. Returns immediately to task agent: `"Conversation started (id: conv-xxx). You'll receive a summary when it completes."`
5. When conversation ends, weaver summary is delivered to spawning agent as a signal
6. Signal injected into task agent's message history as: `[Conversation Summary | Topic: {topic}]: {structured_summary}`

**Acceptance Criteria**:
- [ ] Task agents can spawn conversations via tool call
- [ ] Personas are validated (2-6 participants, required fields)
- [ ] Conversation runs asynchronously — task agent is not blocked
- [ ] Summary is delivered to spawning agent when conversation completes
- [ ] Summary injected into task agent's message history
- [ ] Budget is deducted from team budget, not individual agent budget
- [ ] Facilitator strategy requires facilitator parameter

---

## 13.5: Signal Types & UI Integration

**Complexity**: Medium
**Dependencies**: 13.1, 13.2
**Description**: Define conversation signal types and wire them into the existing comms feed so users can watch conversations unfold in real-time.

**Files to modify**:
- `lib/loomkin/signals/collaboration.ex` — Add conversation signal types
- `lib/loomkin_web/live/workspace_live.ex` — Handle conversation signals
- `lib/loomkin_web/live/agent_comms_component.ex` — Render conversation events

**New signal types**:
```elixir
# Conversation lifecycle
"conversation.started"          # Topic, participants, strategy
"conversation.round.started"    # Round number
"conversation.turn"             # Speaker, content, round
"conversation.reaction"         # Agent reacted (short response)
"conversation.yield"            # Agent yielded turn
"conversation.round.complete"   # Round summary
"conversation.summarizing"      # Weaver generating summary
"conversation.ended"            # Final summary, stats

# Conversation management
"conversation.terminated"       # Force-terminated (by agent or timeout)
"conversation.budget.warning"   # Approaching token limit
```

**Comms feed rendering**:

| Event | Icon | Color | Display |
|---|---|---|---|
| `conversation_started` | dialogue bubble | violet | "Conversation started: {topic} ({n} participants)" |
| `conversation_turn` | speech | slate | "{speaker}: {content}" (full text, not truncated) |
| `conversation_reaction` | emoji | slate-light | "{agent} reacted: {type} — {brief}" |
| `conversation_yield` | skip | gray | "{agent} yielded" |
| `conversation_round_complete` | milestone | violet | "Round {n} complete" |
| `conversation_ended` | checkmark | violet | "Conversation ended ({n} rounds). Expand for summary." |

**Expandable summary on conversation_ended**:
```
Topic: Should we use GenServer or Agent for the cache layer?
Rounds: 6 | Participants: 3 | Tokens: 4,200

Consensus:
  - GenServer with ETS backing for reads
  - Supervision tree with restart strategy

Disagreements:
  - TTL implementation approach (timer vs lazy eviction)

Open Questions:
  - Benchmark needed for ETS vs GenServer reads at scale
```

**Acceptance Criteria**:
- [ ] All conversation signals render in comms feed
- [ ] Conversation turns show full speaker content (not truncated)
- [ ] Conversation summary is expandable with structured sections
- [ ] Users can watch a conversation unfold in real-time
- [ ] Conversation events are visually distinct from task events (violet accent)
- [ ] Multiple concurrent conversations are distinguishable

---

## 13.6: Conversation Templates

**Complexity**: Small
**Dependencies**: 13.4
**Description**: Pre-built persona sets and configurations for common conversation patterns. Makes it easy for task agents (and users) to spawn useful conversations without designing personas from scratch.

**Files to create**:
- `lib/loomkin/conversations/templates.ex`

**Built-in templates**:

```elixir
defmodule Loomkin.Conversations.Templates do
  def brainstorm(topic, context \\ nil) do
    %{
      topic: topic,
      context: context,
      strategy: :round_robin,
      max_rounds: 8,
      personas: [
        %{name: "Innovator", perspective: "Pushes for novel, unconventional approaches", expertise: "Creative problem solving", goal: "Generate unexpected ideas"},
        %{name: "Pragmatist", perspective: "Grounds ideas in practical reality", expertise: "Implementation and delivery", goal: "Identify what's actually buildable"},
        %{name: "Critic", perspective: "Finds weaknesses and risks", expertise: "Risk assessment and edge cases", goal: "Stress-test every idea before it's accepted"}
      ]
    }
  end

  def design_review(topic, context \\ nil) do
    %{
      topic: topic,
      context: context,
      strategy: :facilitator,
      facilitator: "Tech Lead",
      max_rounds: 6,
      personas: [
        %{name: "Tech Lead", perspective: "Balances quality with delivery", expertise: "Architecture and team dynamics", goal: "Drive toward a clear decision"},
        %{name: "Domain Expert", perspective: "Deep knowledge of the problem space", expertise: "Business rules and domain modeling", goal: "Ensure the design fits the domain"},
        %{name: "Maintainer", perspective: "Thinks about long-term code health", expertise: "Refactoring, testing, observability", goal: "Ensure the design is maintainable"}
      ]
    }
  end

  def red_team(topic, context \\ nil) do
    %{
      topic: topic,
      context: context,
      strategy: :round_robin,
      max_rounds: 6,
      personas: [
        %{name: "Advocate", perspective: "Defends the proposal", expertise: "The proposed approach", goal: "Make the strongest case for the current plan"},
        %{name: "Adversary", perspective: "Attacks the proposal", expertise: "Failure modes, security, edge cases", goal: "Find every way this could go wrong"},
        %{name: "User", perspective: "End-user experience", expertise: "UX, accessibility, real-world usage", goal: "Ensure this actually serves users"}
      ]
    }
  end

  def user_panel(topic, context \\ nil) do
    %{
      topic: topic,
      context: context,
      strategy: :facilitator,
      facilitator: "Moderator",
      max_rounds: 8,
      personas: [
        %{name: "Moderator", perspective: "Neutral facilitator", expertise: "User research", goal: "Draw out honest reactions from the panel"},
        %{name: "Power User", perspective: "Uses the product daily, knows all shortcuts", expertise: "Deep product knowledge", goal: "Evaluate against advanced workflows"},
        %{name: "New User", perspective: "Just encountered the product", expertise: "Fresh eyes, no assumptions", goal: "Flag anything confusing or unintuitive"},
        %{name: "Reluctant User", perspective: "Prefers alternatives, skeptical", expertise: "Competitor products", goal: "Explain what would make them switch"}
      ]
    }
  end
end
```

**Usage by task agents**:
```
# Instead of defining personas manually:
spawn_conversation(template: "brainstorm", topic: "How should we structure the notification system?")

# Or with context:
spawn_conversation(template: "red_team", topic: "Our caching strategy", context: "We're using ETS with 10k entries...")
```

**Acceptance Criteria**:
- [ ] Templates produce valid conversation configurations
- [ ] spawn_conversation tool accepts `template` parameter as shorthand
- [ ] Templates can be overridden (e.g., change max_rounds on a brainstorm)
- [ ] At least 4 built-in templates: brainstorm, design_review, red_team, user_panel

---

## 13.7: Testing

**Complexity**: Medium
**Dependencies**: 13.1-13.6
**Description**: Test suite for the conversation system.

**Files to create**:
- `test/loomkin/conversations/server_test.exs`
- `test/loomkin/conversations/agent_test.exs`
- `test/loomkin/conversations/weaver_test.exs`
- `test/loomkin/conversations/turn_strategy_test.exs`
- `test/loomkin/conversations/templates_test.exs`
- `test/loomkin/tools/spawn_conversation_test.exs`

**Testing strategy**:

- **ConversationServer**: Test turn ordering, round advancement, termination conditions (max rounds, all yield, timeout, budget), history management. Use deterministic turn strategies.
- **ConversationAgent**: Mock LLM responses. Verify system prompt construction from persona. Verify tool calls are correctly forwarded to ConversationServer.
- **Weaver**: Mock LLM response. Verify summary structure has all required fields. Verify summary is attached to server state.
- **Turn strategies**: Unit test each strategy in isolation. Verify round-robin cycles, weighted prioritizes quiet agents, facilitator respects facilitator's choices.
- **Templates**: Verify each template produces valid configurations with correct persona count and required fields.
- **SpawnConversation tool**: Test persona validation (min 2, max 6). Test template resolution. Test async return behavior. Mock ConversationServer start.
- **Integration**: Start a 3-agent conversation with mocked LLM, run to completion, verify summary is delivered to spawning agent.

**Acceptance Criteria**:
- [ ] All termination conditions tested (max rounds, budget, all yield, timeout, force terminate)
- [ ] Turn strategies produce correct speaker ordering
- [ ] Conversation agents clean up after conversation ends
- [ ] Summary delivery to spawning agent verified end-to-end
- [ ] Concurrent conversations don't interfere with each other
- [ ] Budget tracking is accurate across all agents in a conversation

---

## Implementation Order

```
13.1 ConversationServer ──> 13.2 ConversationAgent ──> 13.3 Weaver
         |                           |                       |
         v                           v                       v
      13.5 Signals & UI          13.4 Spawn Tool ──> 13.6 Templates
                                                          |
                                                          v
                                                     13.7 Testing
```

**Recommended order**:
1. **13.1** ConversationServer (foundation — shared history + turn management)
2. **13.2** ConversationAgent (can test with ConversationServer)
3. **13.3** Weaver (summarization — completes the conversation lifecycle)
4. **13.4** SpawnConversation tool (task agent integration — this is the deliverable)
5. **13.5** Signals & UI (makes conversations visible in the workspace)
6. **13.6** Templates (convenience layer — makes the feature accessible)
7. **13.7** Testing (throughout, but final coverage pass here)

**Phase gate**: After 13.4, the system is functionally complete — task agents can spawn conversations and receive summaries. 13.5 and 13.6 are polish.

## Risks & Open Questions

1. **Cost control.** A 6-agent conversation running 10 rounds = 60 LLM calls. Even with a fast model, that's meaningful cost. The budget cap is essential. Consider: should conversations count against the team budget, or have their own separate budget?

2. **Quality of dialogue.** Small models (Haiku) may produce shallow, repetitive dialogue. The persona prompt engineering in 13.2 is critical. May need to allow model override per conversation for higher-stakes deliberations.

3. **Conversation length.** Too few rounds = shallow. Too many = repetitive. The all-yield termination (agents naturally stop when they have nothing to add) should handle this, but needs testing with real LLM responses.

4. **Blocking vs async.** Current design is async (task agent spawns and continues). Should there be a blocking variant where the task agent waits for the summary? This is simpler but prevents the task agent from doing other work during deliberation.

5. **User-initiated conversations.** This epic focuses on task-agent-spawned conversations. Should users be able to spawn conversations directly from the UI? (Probably yes, but it's a separate UI feature — could be a follow-up.)

6. **Conversation visibility to other task agents.** Should the conversation summary be broadcast to the whole team, or only returned to the spawning agent? Probably configurable — private deliberation vs team-visible brainstorm.

7. **Persona quality.** Task agents generating good personas is non-trivial. The templates in 13.6 help, but custom personas may need guardrails (minimum fields, perspective diversity check).
