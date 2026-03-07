<p align="center">
  <img src="assets/loomkin-banner.jpg" alt="Loomkin — The Weaver Owl" width="600">
</p>

# Loomkin

[![CI](https://github.com/bleuropa/loomkin/actions/workflows/ci.yml/badge.svg)](https://github.com/bleuropa/loomkin/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Discord](https://img.shields.io/discord/1465498806698119317?color=5865F2&logo=discord&logoColor=white&label=Discord)](https://discord.gg/WUVneqArVD)
[![Elixir](https://img.shields.io/badge/Elixir-1.18+-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Last Commit](https://img.shields.io/github/last-commit/bleuropa/loomkin)](https://github.com/bleuropa/loomkin/commits/main)

**What if AI agents could form teams as fluidly as humans?**

Spawn specialists in milliseconds. Share discoveries in real-time. Review each other's work. Debate approaches and vote on decisions. Remember everything across sessions -- not just what happened, but *why*.

Watch it all unfold from a live mission control UI. Built on Erlang/OTP.

- **Decision graph** — persistent reasoning memory that survives across sessions (not just chat history)
- **Context mesh** — overflow is offloaded to Keeper processes, never summarized away. 228K+ tokens preserved vs 128K with zero loss
- **Agent teams** — OTP-native, <500ms spawn, microsecond coordination. 10 cheap agents for ~$0.25 vs ~$4.50 single-Opus
- **LiveView web UI** — 13 components, zero JavaScript. Streaming chat, interactive SVG decision graph, team dashboard, cost analytics
- **28 built-in tools**, 16 LLM providers, 665+ models via [req_llm](https://github.com/agentjido/req_llm)
- **Hot code reloading** — update tools, providers, and prompts without restarting sessions or losing state

[loomkin.dev](https://loomkin.dev) | Built on [Jido](https://github.com/agentjido/jido) | 122 source files, ~20,000 LOC, 925+ tests

<p align="center">
  <img src="assets/loomkin-example.jpg" alt="Loomkin example session — fixing a failing test" width="700">
</p>

---

## How Loomkin is Different

| | Traditional AI Assistants | Loomkin |
|---|---|---|
| **Default experience** | Single agent, teams opt-in | Teams-first: every session is a team of 1+ that auto-scales |
| **Memory** | Conversation history, maybe embeddings | Persistent decision graph — goals, tradeoffs, rejected approaches survive across sessions |
| **Context** | Summarized away as it grows (lossy) | Context Mesh: offloaded to Keeper processes, zero loss, 228K+ tokens preserved |
| **Agent spawn** | 20-30 seconds | <500ms (`GenServer.start_link`) |
| **Inter-agent messaging** | JSON files on disk, polled | In-memory PubSub, microsecond latency |
| **Concurrent file edits** | Overwrite risk | Region-level locking with intent broadcasting |
| **Task decomposition** | Lead plans upfront, frozen | Living plans: agents create tasks, propose revisions, re-plan as they learn |
| **Peer review** | None | Native protocol — review gates, pair programming mode |
| **Agent concurrency** | 3-5 practical limit | 100+ lightweight processes per node |
| **Model mixing** | Single model for all agents | Per-agent selection — cheap grunts + expensive judges (18x cost savings) |
| **Web UI** | Terminal only, or separate web app | Full LiveView workspace — chat, files, diffs, decision graph, team dashboard. Zero JS |
| **Decision persistence** | None | PostgreSQL DAG with 7 node types, typed edges, confidence scores, pulse reports |
| **MCP** | Client or server | Both — expose tools to editors AND consume external tools |
| **Fault tolerance** | Crash = lost session | OTP supervisors restart crashed tools/sessions/agents automatically |
| **Hot reload** | Restart required | Update tools, providers, prompts while agents are running |

[Why Elixir and the BEAM?](docs/why-elixir.md)

---

## Getting Started

### Prerequisites

- Elixir 1.18+ (with Erlang/OTP 27+) — versions pinned in `.mise.toml`
- Docker (we recommend [OrbStack](https://orbstack.dev) on macOS — fast, lightweight Docker runtime)
- Node.js 22 — for asset compilation
- An API key for at least one LLM provider (Anthropic, OpenAI, Google, etc.)

> **No Docker?** If you prefer system-installed Postgres, set `DB_PORT=5432` (or your custom port) in your environment and skip the `make db.up` step.

### Install

```bash
git clone https://github.com/bleuropa/loomkin.git
cd loomkin

# Install deps, start Postgres container, set up the database
make setup

# Start the web UI
make dev
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

[permissions]
auto_approve = ["file_read", "file_search", "content_search", "directory_list"]
```

[Full configuration reference](docs/configuration.md)

### Run

```bash
# Web UI — streaming chat, file tree, decision graph, team dashboard
mix phx.server
# → http://localhost:4200
```

---

## Features

### Intelligence

- **Decision graph** — persistent DAG of goals, decisions, and outcomes (7 node types, typed edges, confidence tracking). Cascade uncertainty propagation warns downstream nodes when confidence drops. Auto-logging captures lifecycle events. Narrative generation builds timeline summaries. Pulse reports surface coverage gaps and stale decisions. Interactive SVG visualization in the web UI
- **Context mesh** — agents offload context to Keeper processes instead of summarizing it away. Any agent can retrieve the full conversation from any other agent's history. Semantic search across keepers via cheap LLM calls. Total context grows with the task instead of shrinking
- **Token-aware context window** — automatic budget allocation across system prompt, decision context, repo map, conversation history, and tool definitions
- **Tree-sitter repo map** — symbol extraction across 7 languages (Elixir, JS/TS, Python, Ruby, Go, Rust) with ETS caching and regex fallback

### Agent Teams

- **OTP-native** — each agent is a GenServer under a DynamicSupervisor. Spawn in <500ms, communicate via PubSub in microseconds. 100+ concurrent agents per node
- **5 built-in roles** — lead, researcher, coder, reviewer, tester. Each with scoped tools and tailored system prompts. Custom roles configurable via `.loomkin.toml`
- **Structured debate** — propose/critique/revise/vote cycle for complex decisions
- **Pair programming** — dedicated coder + reviewer pairing with real-time event exchange
- **Cross-session learning** — records task outcomes, recommends team compositions and models for future tasks
- **Per-team budget tracking** — token bucket rate limiting, per-agent spend limits, model escalation chains (cheap model fails twice → auto-escalate)
- **Region-level file locking** — multiple agents safely edit the same file by claiming line ranges or symbols
- **Team orchestration dashboard** — LiveView UI with real-time agent status, activity feed, cost tracking ([deep dive](docs/agent-teams.md))

### Interfaces

- **Phoenix LiveView web UI** — 13 components, zero JavaScript: streaming chat, file tree, unified diffs, interactive SVG decision graph, model selector, session switcher, tool approval modals, terminal viewer, team dashboard, team activity feed, team cost tracker, cost analytics dashboard
- **MCP server + client** — expose Loomkin's tools to VS Code/Cursor/Zed; consume external tools from Tidewave, HexDocs, and any MCP server. Bidirectional by default
- **Architect/Editor mode** — strong model (e.g. Opus) plans edits, fast model (e.g. Haiku) executes them. Can spawn full teams for complex tasks instead of file-based plans. 918 LOC of two-model orchestration

### Infrastructure

- **28 built-in tools** — file ops, glob/regex search, shell, git, LSP diagnostics, decision logging/querying, sub-agent search, team management (spawn/assign/dissolve/progress), peer communication (message/discovery/review/claim region/create task/ask/answer), context offload/retrieve
- **16 LLM providers** — Anthropic, OpenAI, Google, Z.AI, xAI, Groq, DeepSeek, OpenRouter, Mistral, Cerebras, Together AI, Fireworks AI, Cohere, Perplexity, NVIDIA, Azure. 665+ models via req_llm
- **LSP client** — compiler errors/warnings from ElixirLS, next-ls, and other language servers
- **File watcher** — OS-native with 200ms debounce, `.gitignore` filtering, automatic ETS index + repo map refresh
- **Session persistence** — save/resume conversations with full history in PostgreSQL
- **Permission system** — per-tool, per-path approval with session-scoped grants
- **LLM retry** — exponential backoff with transient vs permanent error classification
- **Hot code reloading** — update tools, add providers, tweak prompts without restarting sessions
- **Telemetry + cost dashboard** — per-session costs, model usage breakdown, tool execution frequency at `/dashboard`

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      INTERFACES                          │
│  ┌──────────────┐  ┌──────────────┐                      │
│  │ LiveView Web  │  │ Headless API │                      │
│  └──────┬───────┘  └──────┬───────┘                      │
│         └─────────────────┘                              │
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
│  Tool Layer (28 Jido Actions)                            │
│  File I/O │ Search │ Shell │ Git │ LSP │ Decisions │     │
│  Sub-Agent │ Team Mgmt │ Peer Comms │ Context Mesh       │
├──────────────────────────────────────────────────────────┤
│  Intelligence: Decision Graph │ Repo Intel │ Context Win  │
├──────────────────────────────────────────────────────────┤
│  Protocols: MCP Server │ MCP Client │ LSP Client         │
├──────────────────────────────────────────────────────────┤
│  LLM Layer: req_llm (16 providers, 665+ models)         │
├──────────────────────────────────────────────────────────┤
│  Telemetry + Observability                               │
└──────────────────────────────────────────────────────────┘
```

[Full architecture deep dive — decision graph, Jido foundation, project structure](docs/architecture.md)

---

## Project Rules

Create a `LOOMKIN.md` in your project root to give Loomkin persistent instructions:

```markdown
# Project Instructions

This is a Phoenix LiveView app using Ecto with PostgreSQL.

## Rules
- Always run `mix format` after editing .ex files
- Run `mix test` before committing
- Use `binary_id` for all primary keys

## Allowed Operations
- Shell: `mix *`, `git *`, `elixir *`
- File Write: `lib/**`, `test/**`, `priv/repo/migrations/**`
- File Write Denied: `config/runtime.exs`, `.env*`
```

---

## Roadmap

Loomkin is in active development. Phases 1-4 are complete. Phase 5 (Agent Teams) core is built, hardening in progress.

- **Done**: Phases 1-4 complete. Phase 5 (Agent Teams) core complete including Epic 5.19 — Decision Graph as Shared Nervous System (auto-logging, discovery broadcasting, confidence cascades, cross-session memory)
- **Now**: Epic 5.16 (UI Polish), Epic 5.18 (Observability & Testing)
- **Future**: Phase 6 — Reactive Agent Runtime (async LLM calls, priority message routing, live steering from LiveView)

---

## Acknowledgments

Loomkin wouldn't exist without these projects:

- **[Phoenix](https://github.com/phoenixframework/phoenix)** + **[LiveView](https://github.com/phoenixframework/phoenix_live_view)** — the framework that makes a 13-component real-time web UI possible without writing JavaScript. The foundation of everything users see.
- **[Jido](https://github.com/agentjido/jido)** by the AgentJido team — the Elixir-native agent framework that provides Loomkin's tool system, action composition, AI agent strategies, and shell sandboxing. Jido is to Elixir agents what Phoenix is to Elixir web apps.
- **[Deciduous](https://github.com/juspay/deciduous)** by Juspay — pioneered the concept of structured decision graphs for AI agents. Loomkin's decision graph is a native Elixir implementation of the patterns Deciduous proved out in Rust.
- **[req_llm](https://github.com/agentjido/req_llm)** — unified LLM client for Elixir with 16 providers and 665+ models. Every LLM call in Loomkin goes through req_llm.
- **[Aider](https://github.com/paul-gauthier/aider)** — the gold standard for AI coding assistants. Loomkin's repo map and context packing draw from Aider's approach, with ETS caching and BEAM-native parallelism for symbol extraction.
- **[Claude Code](https://claude.ai/claude-code)** — Anthropic's CLI agent that demonstrated the power of tool-using AI assistants and multi-agent coordination patterns.

---

## Contributing

Loomkin is in active development. Contributions welcome. **925+ tests across 83 files. ~20,000 LOC application code. ~13,000 LOC tests.**

```bash
# Full setup (Docker, deps, database)
make setup

# Start the dev server
make dev

# Run tests
make test

# Format code
make format

# Database lifecycle
make db.up      # start Postgres container
make db.down    # stop Postgres container
make db.reset   # drop, create, migrate, seed
```

---

## License

MIT
