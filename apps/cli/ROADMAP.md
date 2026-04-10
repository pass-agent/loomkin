# Loomkin CLI — Roadmap

## Phase 1: MVP Chat Interface ✅

- [x] Project scaffold (package.json, tsconfig, entry point)
- [x] Config persistence (~/.loomkin/config.json via `conf`)
- [x] First-run setup wizard with @clack/prompts (server URL, auth)
- [x] REST API client for auth, sessions, models
- [x] Phoenix WebSocket connection (adapted from mobile client)
- [x] Zustand stores (app state, session/messages)
- [x] Core components: App, StatusBar, MessageList, Message, InputArea
- [x] Markdown rendering in terminal (marked-terminal)
- [x] Tool call display (name, spinner, result preview)
- [x] Slash command registry with autocomplete
- [x] Commands: /help, /clear, /mode, /model, /compact, /session, /quit, /mcp (stub)
- [x] Command palette with arrow key navigation
- [x] Input history (up/down arrow recall)
- [x] CLI flags: --server, --model, --mode, --session, --new
- [x] Session auto-creation on launch
- [x] Streaming response display
- [x] Connection reconnect handling
- [x] Error display and recovery

## Phase 2: MCP + File Operations (6/8)

- [x] `/mcp` — list connected MCP servers, view tools, refresh endpoints
- [x] `/files` — file browser with search, read, and grep (`/files search`, `/files read`, `/files grep`)
- [x] `/settings` — view/edit server settings from terminal (browse tabs, update values, search)
- [x] `/status` — show server health, connection, providers, sessions, errors
- [x] Session persistence (auto-resume last session, `--new` flag, `/session new`, `/session archive`)
- [x] `/diff` — git diff with syntax highlighting (`/diff [file] [--staged]`)
- [ ] `/mcp add <url>` / `/mcp remove <name>` — dynamic MCP server management (requires config API)
- [ ] Extract shared types to `packages/shared-types/` (mobile + CLI)

## Phase 3: Agent Integration ✅

- [x] Signal forwarding — session channel subscribes to session/team/agent signals
- [x] Tool call approval / permission flow (PermissionPrompt component + channel handlers)
- [x] `ask_user` prompt flow (AskUserPrompt component + channel handlers)
- [x] `/session list` — browse and switch between recent sessions
- [x] `/agents` — list active agents with status, role, current tool/task, cost
- [x] Agent status in StatusBar (working/total count)
- [x] Agent store (Zustand) with real-time updates from channel events
- [x] `/spawn <role> [name]` — spawn agents into session team (auto-creates team)
- [x] `/backlog` — full backlog management (list, add, start, done, block, show)
- [x] `/logs` — decision log viewer (goals, recent, pulse, search)
- [x] Notification system (agent spawn, completion, errors, team dissolved → inline system messages)
- [x] Split-pane agent view (primary + sub-agent output) — `Ctrl+T` toggle, `Tab` switch focus, `[`/`]` cycle agents
- [x] Agent-to-agent message watching (peer messages, conversations, debates, votes → inline notifications)

## Phase 4: Power User Features

- [x] `/share` — live session sharing (create, list, revoke share links with view/collaborate permissions)
- [x] Split pane views (configurable layout with Ink `<Box>`) — implemented via `SplitPaneLayout` component + `paneStore`
- [x] `/theme` — 6 built-in themes: Loomkin (brand, default), Default, High Contrast, Deuteranopia, Tritanopia, Monochrome + colorblind-friendly presets + setup wizard integration
- [x] `/export` — export conversations to markdown or JSON (`/export [--json] [--file <path>]`)
- [x] CLI flags — automation & safety tier:
  - `--print, -p` — non-interactive mode (send prompt, print response, exit)
  - `--output-format` — `text` or `json` output for `--print`
  - `--cwd, -c` — override working directory
  - `--verbose, -v` — verbose logging (socket events, API calls)
  - `--debug` — full error stack traces and state changes
  - `--resume, -r` — explicitly resume most recent session
  - `--system-prompt` — prepend custom system prompt to session
  - `--dangerously-skip-permissions` — auto-approve all tool calls
  - `--allowed-tools` — comma-separated tool allowlist
  - `--disallowed-tools` — comma-separated tool denylist
  - `--max-turns` — limit agent turns before stopping
- [x] Vim keybindings mode — `/keybinds vim` with normal/insert modes, hjkl navigation, word motion, undo, block cursor, StatusBar indicator, persisted to config
- [x] Session management UI — `/session info`, `/session rename`, `/session search`, `/session archive`, `/session list`
- [ ] Plugin system for custom slash commands
- [ ] Shell integration (pipe stdin/stdout for scripting)
- [ ] Tab completion for file paths and model names
- [ ] `/watch` — watch mode for file changes triggering agent actions
- [x] `/prompt` — custom prompt templates with `{{variable}}` placeholders (save, load, show, edit, delete) stored in `~/.loomkin/prompts/`
- [ ] Key binding customization (`~/.loomkin/keybindings.json`)

## Phase 5: CLI Flags — Future Additions

- [ ] `--no-color` — disable ANSI colors (for piping to files)
- [ ] `--quiet, -q` — suppress non-essential output (spinners, status)
- [ ] `--timeout` — global timeout for `--print` mode (exit after N seconds)
- [ ] `--config` — path to alternate config file (instead of `~/.loomkin/config.json`)
- [ ] `--log-file` — write verbose/debug output to file instead of stderr
- [ ] `--api-key` — pass API key directly (for CI, skip auth wizard)
- [ ] `--prompt-file` — read prompt from file (alternative to stdin piping)
- [ ] `--continue` — continue last message in existing session (append, don't create new turn)
- [ ] `--json-stream` — NDJSON streaming output for `--print` (one JSON object per event)
- [ ] `--tool-timeout` — per-tool execution timeout
- [ ] `--dry-run` — show what would happen without executing tools
- [ ] `--cost-limit` — stop if estimated cost exceeds threshold

## Architecture Decisions

| Decision          | Rationale                                                       |
| ----------------- | --------------------------------------------------------------- |
| Bun runtime       | Fast startup, native TypeScript, built-in fetch                 |
| React Ink         | Composable TUI components, React paradigm shared with mobile    |
| @clack/prompts    | Elegant setup wizards outside the Ink render loop               |
| picocolors        | Lightweight terminal colors (replaced chalk for smaller bundle) |
| Zustand           | Same state management as mobile, works outside React            |
| Phoenix JS client | Direct protocol compatibility with loomkin-server channels      |
| marked-terminal   | Rich markdown rendering with syntax highlighting in terminal    |
| conf              | Cross-platform config persistence with schema validation        |
| meow              | Lightweight CLI argument parsing                                |

## Future Considerations

- **packages/shared-types/**: Extract types shared between mobile and CLI
- **packages/phoenix-client/**: If desktop also needs WS, extract shared socket wrapper
- **Binary distribution**: Bun compile for single-binary releases (macOS, Linux)
- **CI/CD**: Add `cli.build` + `cli.test` to GitHub Actions matrix
