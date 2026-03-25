# Configuration

Loomkin is configured through a combination of `.loomkin.toml` files and environment variables.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ANTHROPIC_API_KEY` | Anthropic API key | — |
| `OPENAI_API_KEY` | OpenAI API key | — |
| `GOOGLE_API_KEY` | Google AI API key | — |
| `DATABASE_URL` | PostgreSQL connection URL | — |
| `PORT` | Web UI port | `4200` |
| `SECRET_KEY_BASE` | Phoenix secret key | Derived from `$HOME` |

## `.loomkin.toml`

Create a `.loomkin.toml` in your project root to configure Loomkin per-project. Here's a fully annotated example:

```toml
# ── Model Selection ──────────────────────────────────────
[model]
default = "anthropic:claude-sonnet-4-6"     # primary model for all interactions
weak = "anthropic:claude-haiku-4-5"          # cheap model for summarization, commit messages
architect = "anthropic:claude-opus-4-6"      # strong model for architect mode planning
editor = "anthropic:claude-haiku-4-5"        # fast model for architect mode execution

# ── Permissions ──────────────────────────────────────────
[permissions]
# Tools listed here skip the approval prompt
auto_approve = ["file_read", "file_search", "content_search", "directory_list"]

# ── Context Window Budgets ───────────────────────────────
[context]
max_repo_map_tokens = 2048                   # tokens reserved for repo map
max_decision_context_tokens = 1024           # tokens reserved for decision graph context
reserved_output_tokens = 4096                # tokens reserved for model output

# ── Decision Graph ───────────────────────────────────────
[decisions]
enabled = true                               # enable decision graph tracking
enforce_pre_edit = false                      # require decision log before file edits
auto_log_commits = true                      # auto-log git commits to the graph

# ── MCP (Model Context Protocol) ────────────────────────
[mcp]
server_enabled = true                        # expose Loomkin tools via MCP to editors
servers = [                                  # external MCP servers to connect to
  { name = "tidewave", command = "mix", args = ["tidewave.server"] },
  { name = "hexdocs", url = "http://localhost:3001/sse" }
]

# ── LSP (Language Server Protocol) ───────────────────────
[lsp]
enabled = true
servers = [
  { name = "elixir-ls", command = "elixir-ls", args = [] }
]

# ── Repository Intelligence ──────────────────────────────
[repo]
watch_enabled = true                         # auto-refresh index on file changes

# ── Agent Teams ──────────────────────────────────────────
[teams]
enabled = true
max_agents_per_team = 10
max_concurrent_teams = 3

[teams.budget]
max_per_team_usd = 5.00                      # maximum spend per team
max_per_agent_usd = 1.00                     # maximum spend per agent
```

## `.loomkin.toml.example`

A minimal starter config ships with the repo at `.loomkin.toml.example`. Copy it to get started:

```bash
cp .loomkin.toml.example .loomkin.toml
```
## Provider Endpoints (`.loomkin.toml`)

Loomkin supports multiple inference backends that expose an OpenAI-compatible API. This includes local, self-hosted, and cloud-based solutions.

### Supported Backends

| Backend | Default Port | Auth Support | Notes |
|---------|-------------|--------------|-------|
| [Ollama](https://ollama.com/) | `11434` | Yes | Local LLM inference |
| [vLLM](https://github.com/vllm-project/vllm) | `8000` | Yes | High-throughput OpenAI-compatible server |
| [SGLang](https://github.com/sgl-project/sglang) | `30000` | Yes | Efficient LLM serving |
| [LM Studio](https://lmstudio.ai/) (LMS) | `1234` | Yes | Local GUI or CLI on Linux |
| [Exo](https://github.com/exo-explore/exo) | `8080` | Yes | Distributed LLM inference |
| [LiteLLM](https://github.com/BerriAI/litellm) | `4000` | Yes | Proxy for multiple providers |

### Configuration Examples

```toml
[provider.endpoints]
# Ollama (local) - default, ready to use
# ollama = { url = "http://localhost:11434/v1" }

# vLLM (self-hosted)
# vllm = {
#   url = "http://localhost:8000/v1",
#   auth_key = "your-api-key"  # optional, sent as x-api-key header
# }

# SGLang (self-hosted)
# sglang = {
#   url = "http://localhost:30000/v1",
#   auth_key = "your-token"  # optional, sent as Bearer token
# }

# LM Studio (local, GUI or CLI on Linux)
# lms = { url = "http://localhost:1234/v1" }

# Exo (distributed inference)
# exo = {
#   url = "http://localhost:8080/v1",
#   auth_key = "your-token"  # optional
# }

# LiteLLM (multi-provider proxy)
# litellm = { url = "http://localhost:4000/v1" }
```

### How to Use

Once configured, use the provider name followed by a colon and model ID:

```elixir
# Ollama
Loomkin.LLM.stream_text("ollama:qwen3:8b", messages, opts)

# vLLM
Loomkin.LLM.stream_text("vllm:meta-llama/Llama-3.1-8B", messages, opts)

# LM Studio (LMS)
Loomkin.LLM.stream_text("lms:phi-3", messages, opts)

# Exo
Loomkin.LLM.stream_text("exo:llama-3-8b", messages, opts)
```

### Auth Key Handling

Each backend has specific auth header conventions:

| Backend | Auth Header Type | Example |
|---------|-----------------|---------|
| Ollama | `Authorization: Bearer <key or "ollama">` | Default token is `"ollama"` |
| vLLM | `x-api-key: <key>` | Sent as HTTP header |
| SGLang | `Authorization: Bearer <key>` | Bearer token authentication |
| LMS | `Authorization: Bearer <key>` | Compatible with vLLM format |
| Exo | `Authorization: Bearer <key>` | Bearer token authentication |
| LiteLLM | Configurable via LiteLLM settings | Use auth_key if required |

### Notes

- URLs must include the path (`/v1` is standard)
- If `auth_key` is omitted, backend-specific defaults are used
- All backends support streaming and batch inference
- Model discovery is automatic via `/v1/models` endpoint

Note: The `OLLAMA_HOST` environment variable is no longer supported. Use `[provider.endpoints]` in `.loomkin.toml` instead.


## Project Rules (`LOOMKIN.md`)

In addition to `.loomkin.toml`, you can create a `LOOMKIN.md` in your project root to give Loomkin persistent natural-language instructions:

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
