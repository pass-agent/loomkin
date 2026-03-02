<p align="center">
  <img src="assets/loomkin-banner.jpg" alt="Loomkin — The Weaver Owl" width="600">
</p>

# Loomkin

**Elixir-native AI agents that weave code, reasoning, and memory into one thread — as kin.**

Loomkin reads your codebase, proposes edits, runs commands, and commits changes — through both an interactive CLI and a Phoenix LiveView web UI with real-time streaming chat, file browsing, diff viewing, and an interactive decision graph. Every session is a team. One agent or twenty — the architecture is the same. Context is never lost. Agents communicate in microseconds. Cheap models in swarms outperform expensive models solo.

Built on the [Jido](https://github.com/agentjido/jido) agent ecosystem and powered by [req_llm](https://github.com/agentjido/req_llm) for multi-provider LLM access, Loomkin treats AI coding assistance as a proper OTP application — supervised, fault-tolerant, and concurrent by design.

<p align="center">
  <img src="assets/loomkin-example.jpg" alt="Loomkin example session — fixing a failing test" width="700">
</p>

---

## Why Elixir?

Most AI coding tools are built in Python or TypeScript. Loomkinkin is built in Elixir because the BEAM virtual machine is quietly the best runtime for AI agent workloads:

**Concurrency without complexity.** An AI agent that reads files, searches code, runs shell commands, and calls LLMs is inherently concurrent. On the BEAM, each tool execution is a lightweight process. Parallel tool calls aren't a threading nightmare — they're just `Task.async_stream`. No thread pools, no callback hell, no GIL.

**Fault tolerance is built in.** When a shell command hangs or an LLM provider times out, OTP supervisors handle it. A crashed tool doesn't take down the session. A crashed session doesn't take down the application. This isn't defensive coding — it's how the BEAM works.

**LiveView for real-time UI.** No other AI coding assistant offers a real-time web UI with streaming chat, file browsing, diff viewing, and decision graph visualization — without writing a single line of JavaScript. Phoenix LiveView makes this possible. The same session GenServer that powers the CLI powers the web UI. Two interfaces, one source of truth.

**Hot code reloading.** Update Loomkin's tools, add new providers, tweak the system prompt — all without restarting sessions or losing conversation state. In production. While agents are running.

**Pattern matching for LLM responses.** Elixir's pattern matching makes handling the zoo of LLM response formats (tool calls, streaming chunks, error variants, provider-specific quirks) clean and exhaustive rather than a tangle of if/else.

```elixir
# This is real code from Loomkin's agent loop
case ReqLLM.Response.classify(response) do
  %{type: :tool_calls} -> execute_tools_and_continue(response, state)
  %{type: :final_answer} -> persist_and_return(response, state)
  %{type: :error} -> handle_error(response, state)
end
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      INTERFACES                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │   CLI (Owl)   │  │ LiveView Web │  │ Headless API │   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │
│         └─────────────────┼─────────────────┘            │
├───────────────────────────┼──────────────────────────────┤
│  Session Layer            │                              │
│  ┌────────────────────────┴───────────────────────────┐  │
│  │ Session GenServer (per-conversation)                │  │
│  │  ├── Jido.AI.Agent (ReAct reasoning loop)          │  │
│  │  ├── Context Window (token-budgeted history)       │  │
│  │  ├── Decision Graph (persistent reasoning memory)  │  │
│  │  └── Permission Manager (per-tool approval)        │  │
│  └────────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────┤
│  Tool Layer (27 Jido Actions)                            │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌──────────────┐   │
│  │FileRead │ │FileWrite│ │FileEdit │ │ FileSearch   │   │
│  ├─────────┤ ├─────────┤ ├─────────┤ ├──────────────┤   │
│  │  Shell  │ │   Git   │ │SubAgent │ │ContentSearch │   │
│  ├─────────┤ ├─────────┤ ├─────────┤ ├──────────────┤   │
│  │DecisionLog│DecisionQuery│DirList │ │LspDiagnostics│   │
│  ├─────────┤ ├─────────┤ ├─────────┤ ├──────────────┤   │
│  │TeamSpawn│ │TeamAssign│ │TeamDiss.│ │TeamProgress  │   │
│  ├─────────┤ ├─────────┤ ├─────────┤ ├──────────────┤   │
│  │PeerMsg  │ │PeerDisc.│ │PeerReview│ │PeerClaimRgn │   │
│  ├─────────┤ ├─────────┤ ├─────────┤ ├──────────────┤   │
│  │PeerTask │ │PeerAsk  │ │PeerAnswer│ │CtxOffload   │   │
│  └─────────┘ └─────────┘ └─────────┘ └──────────────┘   │
├──────────────────────────────────────────────────────────┤
│  Intelligence Layer                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌─────────────────┐  │
│  │Decision Graph│ │  Repo Intel  │ │ Context Window  │  │
│  │ (7 node types│ │ (ETS index,  │ │ (token budget,  │  │
│  │  DAG in      │ │  tree-sitter │ │  summarization, │  │
│  │  SQLite)     │ │  + file      │ │  compaction)    │  │
│  │              │ │  watcher)    │ │                 │  │
│  └──────────────┘ └──────────────┘ └─────────────────┘  │
├──────────────────────────────────────────────────────────┤
│  Protocol Layer                                          │
│  ┌──────────────┐ ┌──────────────┐ ┌─────────────────┐  │
│  │  MCP Server  │ │  MCP Client  │ │   LSP Client    │  │
│  │ (expose tools│ │ (consume     │ │ (diagnostics    │  │
│  │  to editors) │ │  ext. tools) │ │  from lang      │  │
│  │              │ │              │ │  servers)       │  │
│  └──────────────┘ └──────────────┘ └─────────────────┘  │
├──────────────────────────────────────────────────────────┤
│  LLM Layer: req_llm (16+ providers, 665+ models)        │
│  Anthropic │ OpenAI │ Google │ Groq │ xAI │ Bedrock │…  │
├──────────────────────────────────────────────────────────┤
│  Telemetry + Observability                               │
│  Event emission │ ETS metrics │ Cost dashboard (/dash)   │
└──────────────────────────────────────────────────────────┘
```

### The Decision Graph

Inspired by [Deciduous](https://github.com/juspay/deciduous), Loomkin maintains a persistent DAG of decisions, goals, and outcomes across coding sessions. This is what separates Loomkin from "chat with your code" tools:

- **7 node types**: goal, decision, option, action, outcome, observation, revisit
- **Typed edges**: leads_to, chosen, rejected, requires, blocks, enables, supersedes
- **Confidence tracking**: each node carries a 0-100 confidence score
- **Context injection**: before every LLM call, active goals and recent decisions are injected into the system prompt — token-budgeted so it never blows the context window
- **Pulse reports**: health checks that surface coverage gaps, stale decisions, and low-confidence areas

The graph lives in SQLite (via Ecto) and travels with your project. When you come back to a codebase after a week, Loomkin remembers what you were trying to accomplish, what approaches were tried, and why certain options were rejected.

We chose to implement the decision graph natively in Elixir rather than shelling out to the Rust-based Deciduous CLI. Ecto gives us the same SQLite persistence with composable queries, and LiveView can render the graph interactively without a separate process. Full credit to the Deciduous project for pioneering the concept of structured decision tracking for AI agents.

### The Jido Foundation

Loomkin is built on the [Jido](https://github.com/agentjido/jido) agent ecosystem, and we're grateful for it. Rather than reinventing agent infrastructure, we stand on the shoulders of a thoughtfully designed Elixir-native framework:

- **[jido_action](https://github.com/agentjido/jido_action)** — Every Loomkin tool is a `Jido.Action` with declarative schemas, automatic validation, and composability. No manual parameter parsing, no hand-written JSON Schema.
- **[jido_ai](https://github.com/agentjido/jido_ai)** — The `Jido.AI.ToolAdapter` bridges our actions to LLM tool schemas in one line. `Jido.AI.Agent` provides the ReAct reasoning strategy that drives the agent loop.
- **[jido_shell](https://github.com/agentjido/jido_shell)** — Sandboxed shell execution with resource limits (used for the virtual shell backend).
- **[req_llm](https://github.com/agentjido/req_llm)** — 16+ LLM providers, 665+ models, streaming, tool calling, cost tracking. The engine room of every LLM call Loomkin makes.

The Jido ecosystem saves thousands of lines of code and provides battle-tested infrastructure for the hard problems (tool dispatch, schema validation, provider normalization) so Loomkin can focus on the interesting problems (decision graphs, context intelligence, repo understanding).

---

## Features

### Core (Phases 1-3)

- **Interactive CLI** — REPL-style interface with streaming output, colored diffs, markdown rendering
- **Phoenix LiveView web UI** — real-time streaming chat, file tree browser, unified diff viewer, interactive SVG decision graph, model selector, session switcher, tool permission modal, terminal output viewer — all without writing JavaScript
- **PubSub real-time events** — session status, new messages, tool execution start/complete broadcast over Phoenix PubSub to all connected clients
- **27 built-in tools** — file read/write/edit, glob search, regex search, directory listing, shell execution, git operations, LSP diagnostics, decision logging/querying, sub-agent search, team management (spawn/assign/dissolve/progress), peer communication (message/discovery/review/claim region/create task/ask/answer questions), context offload/retrieval
- **Multi-provider LLM support** — Anthropic, OpenAI, Google, Groq, xAI, and more via req_llm
- **Decision graph** — persistent reasoning memory with 7 node types and typed relationships, with interactive SVG visualization in the web UI
- **Token-aware context window** — automatic budget allocation across system prompt, decision context, repo map, conversation history, and tool definitions
- **Session persistence** — save/resume conversations with full history in SQLite
- **Permission system** — per-tool, per-path approval with session-scoped grants
- **Sub-agent search** — spawns a lightweight read-only agent (weak model) for parallel codebase exploration
- **Project rules** — `LOOMKIN.md` files for per-project instructions and tool permissions
- **Configurable** — `.loomkin.toml` for model selection, context budgets, permission presets

### Production Polish (Phase 4)

- **MCP server** — expose Loomkin tools to VS Code, Cursor, Zed, and other MCP-capable editors via [jido_mcp](https://github.com/agentjido/jido_mcp)
- **MCP client** — connect to external MCP servers (Tidewave, HexDocs, etc.), auto-discover tools, and make them available to the agent alongside built-in tools
- **LSP client** — JSON-RPC stdio client that connects to language servers (ElixirLS, next-ls) and surfaces compiler errors/warnings via the `lsp_diagnostics` tool
- **Tree-sitter repo map** — Port-based tree-sitter integration with enhanced regex fallback. Extracts 15+ symbol types across 7 languages (Elixir, JS/TS, Python, Ruby, Go, Rust) with ETS caching
- **Architect/Editor mode** — two-model workflow where a strong model (e.g. claude-opus) plans edits and a fast model (e.g. claude-haiku) executes them. Toggle via `/architect` in CLI or the web UI
- **File watcher** — OS-native file watching via `file_system` with 200ms debounce, `.gitignore` filtering, and automatic ETS index + repo map cache refresh. Broadcasts changes to LiveView in real-time
- **Telemetry + cost dashboard** — full instrumentation across LLM calls, tool execution, and message persistence. ETS-backed real-time metrics. LiveView dashboard at `/dashboard` with per-session costs, model usage breakdown, and tool execution frequency
- **Single binary packaging** — [Burrito](https://github.com/burrito-elixir/burrito) wraps the BEAM into a self-extracting binary for macOS (aarch64/x86_64) and Linux (x86_64/aarch64). Auto-migrates on startup, stores data at `~/.loomkin/`

### Agent Teams (Phase 5 — Core Complete, Hardening In Progress)

- **OTP-native agent teams** — each agent is a GenServer under a DynamicSupervisor. Agents communicate through Phoenix PubSub in real-time — direct messages, team-wide broadcasts, context updates. No files, no polling, sub-millisecond latency.
- **Zero-loss context mesh** — agents offload context to lightweight Keeper processes instead of summarizing it away. Nothing is ever destroyed — any agent can retrieve the full conversation from any other agent's history. Smart retrieval uses cheap LLM calls to semantically search keeper contents, not just dump raw chunks.
- **Role-based agents** — lead, researcher, coder, reviewer, tester. Each role has scoped tools and a tailored system prompt, but all use the same user-configured model. The swarm's collective intelligence compensates for individual capability.
- **Region-level file locking** — multiple agents can safely edit the same file by claiming specific line ranges or symbols. Intent broadcasting lets peers coordinate before editing.
- **Peer review protocol** — agents request code reviews from each other. Critical paths can require review before edits are applied.
- **Peer communication** — agents ask each other questions, forward queries to specialists, and share discoveries proactively. Context-aware behavior means agents broadcast findings to teammates automatically.
- **Task coordination** — agents create tasks, propose plan revisions, and discover work that needs doing. Plans evolve as the team learns.
- **Per-team budget tracking** — token bucket rate limiting per provider, per-team and per-agent spend tracking with configurable limits. Real-time cost dashboard per team.
- **Team orchestration dashboard** — LiveView team management UI with real-time agent status, task progress, activity feed, and cost tracking. Spawn controls, team switcher, and per-agent visibility.
- **Response streaming** — real-time streaming from team agents to the web UI. Architect mode shows step-by-step progress. Agent activity feed streams tool execution and discoveries as they happen.
- **Permission system** — complete permission flow for team operations with approval modals, architect permission checks, and configurable auto-approve for team agents.
- **Async agent loops** — LLM calls run as `Task.async`, so agents stay responsive to messages even while waiting for model responses. Urgent messages (budget exceeded, file conflicts) can interrupt in-flight work.

---

## Why Agent Teams Belong on the BEAM

Most multi-agent AI systems bolt coordination onto single-threaded runtimes using message queues, file-based communication, or HTTP polling. Loomkin doesn't need any of that — the BEAM virtual machine was literally built for this.

**Every agent is a GenServer.** Spawning an agent is `DynamicSupervisor.start_child/2`. It takes milliseconds, not seconds. An agent crashing doesn't take down the team — OTP supervisors restart it with its last known state. This is the same infrastructure that keeps telecom switches running for decades.

**Communication is native message passing.** Agents talk to each other through Phoenix PubSub — direct messages, team-wide broadcasts, context updates, task assignments. No serialization overhead, no network hops, no message broker to maintain. A PubSub broadcast reaches every agent in under a millisecond.

**Context never gets destroyed.** This is the big one. Every other AI coding tool summarizes or compacts conversation history as it grows, permanently losing information. Loomkin agents offload context to lightweight Keeper processes — GenServers that hold conversation chunks at full fidelity. Any agent can query any keeper to retrieve exactly what was said 200 messages ago. The context mesh means the team's collective memory grows with the task instead of shrinking.

**Cheap models, collective intelligence.** A swarm of affordable models (like GLM-5 at ~$0.95/M tokens) communicating fluidly through OTP can outperform a single expensive model working alone. When every agent has access to the team's shared knowledge, peer review, and real-time coordination, individual model capability matters less than collective capability. The same task that costs $5 with a single Opus call can cost $0.50 with a coordinated team.

Ask Loomkin to refactor a module and it automatically:
1. Spawns **researchers** to analyze usage patterns across the codebase
2. Spawns **coders** that claim specific file regions and implement changes in parallel
3. Spawns a **reviewer** that checks every edit before it's applied
4. Coordinates all of them through PubSub, with the decision graph tracking every choice
5. Any agent can ask the team a question, create new tasks, or propose plan revisions

This isn't a roadmap — the OTP infrastructure, agent communication, task coordination, and context mesh are built and working.

---

## Getting Started

### Prerequisites

- Elixir 1.18+
- An API key for at least one LLM provider (Anthropic, OpenAI, Google, etc.)

### Install

```bash
git clone https://github.com/bleuropa/loomkin.git
cd loomkin

# Install deps and set up the database
mix setup

# Build the CLI escript
mix escript.build

# Start the web UI (optional)
mix phx.server
# → http://localhost:4200
```

### Configure

Set your LLM provider API key:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
# or
export OPENAI_API_KEY="sk-..."
```

Optionally create a `.loomkin.toml` in your project root:

```toml
[model]
default = "anthropic:claude-sonnet-4-6"
weak = "anthropic:claude-haiku-4-5"
architect = "anthropic:claude-opus-4-6"   # strong model for architect mode planning
editor = "anthropic:claude-haiku-4-5"      # fast model for architect mode execution

[permissions]
auto_approve = ["file_read", "file_search", "content_search", "directory_list"]

[context]
max_repo_map_tokens = 2048
max_decision_context_tokens = 1024
reserved_output_tokens = 4096

[mcp]
server_enabled = true                      # expose Loomkin tools via MCP
servers = [                                # external MCP servers to connect to
  { name = "tidewave", command = "mix", args = ["tidewave.server"] },
  { name = "hexdocs", url = "http://localhost:3001/sse" }
]

[lsp]
enabled = true
servers = [
  { name = "elixir-ls", command = "elixir-ls", args = [] }
]

[repo]
watch_enabled = true                       # auto-refresh index on file changes

[teams]
enabled = true
max_agents_per_team = 10
max_concurrent_teams = 3

[teams.budget]
max_per_team_usd = 5.00
max_per_agent_usd = 1.00
```

### Run

```bash
# Web UI — streaming chat, file tree, decision graph
mix phx.server
# → http://localhost:4200

# Interactive CLI — open a REPL in your project
./loomkin --project /path/to/your/project

# One-shot mode — ask a single question
./loomkin --project . "What does the auth module do?"

# Specify a model
./loomkin --model anthropic:claude-sonnet-4-6 --project .

# Resume a previous session
./loomkin --resume <session-id> --project .
```

### CLI Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/model <name>` | Switch LLM model mid-session |
| `/architect` | Toggle architect/editor two-model mode |
| `/history` | Show conversation history |
| `/sessions` | List all saved sessions |
| `/clear` | Clear conversation history |
| `/quit` | Exit Loomkin |

### Project Rules

Create a `LOOMKIN.md` in your project root to give Loomkin persistent instructions:

```markdown
# Project Instructions

This is a Phoenix LiveView app using Ecto with PostgreSQL.

## Rules
- Always run `mix format` after editing .ex files
- Run `mix test` before committing
- Use `binary_id` for all primary keys
- Follow the context module pattern in `lib/myapp/`

## Allowed Operations
- Shell: `mix *`, `git *`, `elixir *`
- File Write: `lib/**`, `test/**`, `priv/repo/migrations/**`
- File Write Denied: `config/runtime.exs`, `.env*`
```

---

## Project Structure

```
loomkin/
├── lib/
│   ├── loomkin/
│   │   ├── application.ex          # OTP supervision tree
│   │   ├── agent.ex                # Jido.AI.Agent definition (tools + config)
│   │   ├── config.ex               # ETS-backed config (TOML + env vars)
│   │   ├── repo.ex                 # Ecto Repo (SQLite)
│   │   ├── tool.ex                 # Shared helpers (safe_path!, param access)
│   │   ├── project_rules.ex        # LOOMKIN.md parser
│   │   ├── session/
│   │   │   ├── session.ex          # Core GenServer + PubSub broadcasting
│   │   │   ├── manager.ex          # Start/stop/find/list sessions
│   │   │   ├── persistence.ex      # SQLite CRUD for sessions + messages
│   │   │   ├── context_window.ex   # Token budget allocation + compaction
│   │   │   └── architect.ex        # Two-model architect/editor workflow
│   │   ├── agent_loop.ex           # Shared ReAct loop (sessions + team agents)
│   │   ├── teams/
│   │   │   ├── supervisor.ex       # Registry + DynamicSupervisor + RateLimiter
│   │   │   ├── agent.ex            # Agent GenServer (team member runtime)
│   │   │   ├── manager.ex          # Team lifecycle API (create, spawn, dissolve)
│   │   │   ├── role.ex             # Role definitions (lead, researcher, coder, reviewer, tester)
│   │   │   ├── rate_limiter.ex     # Token bucket + per-team/per-agent budget
│   │   │   ├── comms.ex            # PubSub utilities for team communication
│   │   │   ├── context.ex          # ETS shared state per team
│   │   │   ├── context_keeper.ex   # Holds offloaded context at full fidelity
│   │   │   ├── context_offload.ex  # Topic boundary detection + offloading logic
│   │   │   ├── context_retrieval.ex # Cross-agent context discovery + retrieval
│   │   │   ├── tasks.ex            # Task CRUD + scheduling
│   │   │   ├── model_router.ex     # Model selection + opt-in escalation
│   │   │   ├── cost_tracker.ex     # Per-team/per-agent cost accounting
│   │   │   ├── query_router.ex     # Cross-agent question routing
│   │   │   ├── table_registry.ex   # ETS table lifecycle management
│   │   │   ├── templates.ex        # Team composition templates
│   │   │   ├── pricing.ex          # Model cost lookups
│   │   │   ├── migration.ex        # Team data migrations
│   │   │   ├── debate.ex           # Multi-agent debate protocol
│   │   │   ├── pair_mode.ex        # Coder + reviewer pair programming
│   │   │   ├── learning.ex         # Team pattern learning
│   │   │   ├── cluster.ex          # Distributed team support
│   │   │   └── distributed.ex      # Cross-node agent communication
│   │   ├── tools/                  # Jido.Action tool modules
│   │   │   ├── registry.ex         # Tool discovery + Jido.Exec dispatch
│   │   │   ├── file_read.ex        # Core tools (12)
│   │   │   ├── file_write.ex
│   │   │   ├── file_edit.ex
│   │   │   ├── file_search.ex
│   │   │   ├── content_search.ex
│   │   │   ├── directory_list.ex
│   │   │   ├── shell.ex
│   │   │   ├── git.ex
│   │   │   ├── lsp_diagnostics.ex
│   │   │   ├── decision_log.ex
│   │   │   ├── decision_query.ex
│   │   │   ├── sub_agent.ex
│   │   │   ├── team_spawn.ex       # Team lead tools (4)
│   │   │   ├── team_assign.ex
│   │   │   ├── team_dissolve.ex
│   │   │   ├── team_progress.ex
│   │   │   ├── peer_message.ex     # Peer communication tools (9)
│   │   │   ├── peer_discovery.ex
│   │   │   ├── peer_review.ex
│   │   │   ├── peer_claim_region.ex
│   │   │   ├── peer_create_task.ex
│   │   │   ├── peer_ask_question.ex
│   │   │   ├── peer_answer_question.ex
│   │   │   ├── peer_forward_question.ex
│   │   │   ├── peer_change_role.ex
│   │   │   ├── context_offload.ex  # Context mesh tools (2)
│   │   │   └── context_retrieve.ex
│   │   ├── decisions/              # Deciduous-inspired decision graph
│   │   │   ├── graph.ex            # CRUD + queries
│   │   │   ├── pulse.ex            # Health reports
│   │   │   ├── narrative.ex        # Timeline generation
│   │   │   └── context_builder.ex  # LLM context injection
│   │   ├── repo_intel/             # Repository intelligence
│   │   │   ├── index.ex            # ETS file catalog
│   │   │   ├── repo_map.ex         # Symbol extraction + ranking
│   │   │   ├── tree_sitter.ex      # Tree-sitter + enhanced regex parser (7 langs)
│   │   │   ├── context_packer.ex   # Tiered context assembly
│   │   │   └── watcher.ex          # OS-native file watcher with debounce
│   │   ├── mcp/                    # Model Context Protocol
│   │   │   ├── server.ex           # Expose tools to editors via MCP
│   │   │   ├── client.ex           # Consume external MCP tools
│   │   │   └── client_supervisor.ex
│   │   ├── lsp/                    # Language Server Protocol
│   │   │   ├── client.ex           # JSON-RPC stdio LSP client
│   │   │   ├── protocol.ex         # LSP message encoding/decoding
│   │   │   └── supervisor.ex       # LSP process supervision
│   │   ├── telemetry.ex            # Event emission helpers
│   │   ├── telemetry/
│   │   │   └── metrics.ex          # ETS-backed real-time metrics
│   │   ├── release.ex              # Release tasks (migrate, create_db)
│   │   ├── permissions/            # Tool permission system
│   │   │   ├── manager.ex
│   │   │   └── prompt.ex
│   │   └── schemas/                # Ecto schemas (SQLite)
│   ├── loomkin_web/                   # Phoenix LiveView web UI
│   │   ├── endpoint.ex             # Bandit HTTP endpoint
│   │   ├── router.ex               # Browser routes + LiveDashboard
│   │   ├── components/
│   │   │   ├── core_components.ex  # Flash, form, input, button helpers
│   │   │   ├── layouts.ex          # Layout module
│   │   │   └── layouts/            # Root + app HTML templates
│   │   ├── controllers/
│   │   │   ├── error_html.ex       # HTML error pages
│   │   │   └── error_json.ex       # JSON error responses
│   │   └── live/                   # LiveView components
│   │       ├── workspace_live.ex         # Main split-screen layout
│   │       ├── chat_component.ex         # Streaming chat with markdown
│   │       ├── file_tree_component.ex    # Recursive file browser
│   │       ├── diff_component.ex         # Unified diff viewer
│   │       ├── decision_graph_component.ex # Interactive SVG DAG
│   │       ├── model_selector_component.ex # Multi-provider model picker
│   │       ├── session_switcher_component.ex # Session management
│   │       ├── permission_component.ex   # Tool approval modal
│   │       ├── terminal_component.ex     # Shell output renderer
│   │       ├── cost_dashboard_live.ex    # Telemetry + cost dashboard
│   │       ├── team_dashboard_component.ex # Team orchestration UI
│   │       ├── team_activity_component.ex  # Real-time agent activity feed
│   │       └── team_cost_component.ex    # Per-team budget + spend tracking
│   └── loomkin_cli/                   # CLI interface
│       ├── main.ex                 # Escript entry point
│       ├── interactive.ex          # REPL loop
│       └── renderer.ex             # ANSI markdown + diff rendering
├── assets/                         # Frontend assets
│   ├── js/app.js                   # LiveSocket + hooks (ShiftEnterSubmit, ScrollToBottom)
│   ├── css/app.css                 # Tailwind dark theme
│   └── tailwind.config.js          # Tailwind configuration
├── priv/repo/migrations/           # SQLite migrations
├── test/                           # 800+ tests across 77 files
├── config/                         # Dev/test/prod/runtime config
└── docs/                           # Architecture + migration docs
```

**~117 source files. ~19,000 LOC application code. ~11,000 LOC tests.**

---

## Acknowledgments

Loomkin wouldn't exist without these projects:

- **[Jido](https://github.com/agentjido/jido)** by the AgentJido team — the Elixir-native agent framework that provides Loomkinkin's tool system, action composition, AI agent strategies, and shell sandboxing. Jido is to Elixir agents what Phoenix is to Elixir web apps.
- **[Deciduous](https://github.com/juspay/deciduous)** by Juspay — pioneered the concept of structured decision graphs for AI agents. Loomkin's decision graph is a native Elixir implementation of the patterns Deciduous proved out in Rust.
- **[req_llm](https://github.com/agentjido/req_llm)** — unified LLM client for Elixir with 16+ providers and 665+ models. Every LLM call in Loomkin goes through req_llm.
- **[Aider](https://github.com/paul-gauthier/aider)** — the gold standard for AI coding assistants. Loomkin's repo map, context packing, and edit format are inspired by Aider's approach.
- **[Claude Code](https://claude.ai/claude-code)** — Anthropic's CLI agent that demonstrated the power of tool-using AI assistants and multi-agent coordination patterns.

---

## Building a Standalone Binary

Loomkin can be packaged as a single self-contained binary using [Burrito](https://github.com/burrito-elixir/burrito). The binary bundles the BEAM runtime, so users don't need Elixir or Erlang installed.

### Quick Build (current platform)

```bash
# Build a release binary for your current OS/arch
MIX_ENV=prod mix release loomkin

# The binary will be in burrito_out/
./burrito_out/loomkin_macos_aarch64
```

### Cross-Platform Builds

```bash
# Build for all configured targets
MIX_ENV=prod mix release loomkin

# Targets (configured in mix.exs):
#   macos_aarch64  — Apple Silicon Mac
#   macos_x86_64   — Intel Mac
#   linux_x86_64   — Linux x86_64
#   linux_aarch64  — Linux ARM64
```

### Standard Mix Release (without Burrito)

If you prefer a standard OTP release without Burrito wrapping:

```bash
# Comment out the Burrito steps in mix.exs releases config, then:
MIX_ENV=prod mix release loomkin

# Run the release
_build/prod/rel/loomkin/bin/loom start

# Or run migrations manually
_build/prod/rel/loomkin/bin/loom eval "Loomkin.Release.migrate()"
```

### Release Behavior

- Database is stored at `~/.loomkin/loomkin.db` (override with `LOOMKIN_DB_PATH`)
- Migrations run automatically on startup
- Web UI starts on port 4200 (override with `PORT`)
- A deterministic secret key base is derived from your home directory (override with `SECRET_KEY_BASE`)

### Cost Dashboard

Visit `/dashboard` in the web UI to see real-time telemetry:
- Per-session token usage and cost tracking
- Model usage breakdown
- Tool execution frequency and performance

---

## Contributing

Loomkin is in active development. Contributions welcome.

```bash
# Run tests
mix test

# Run with verbose output
mix test --trace

# Start the dev server with live reload
mix phx.server

# Format code
mix format
```

---

## License

MIT
