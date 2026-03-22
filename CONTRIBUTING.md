# Contributing to Loomkin

Welcome! Loomkin is an AI agent orchestration platform built with Elixir, Phoenix LiveView, and PostgreSQL. Whether you're fixing a typo, adding a feature, or just exploring -- we're glad you're here.

Come build with us. The repo is young and moving fast -- exciting times.

## Philosophy

**Use whatever tools make you effective.** AI agents, Tidewave, Copilot, Claude Code -- go for it. We're not on a high horse about this. We're building an AI agent platform; it would be weird to ban AI from contributing to it. If you have an AI workflow you trust, use it. As long as the PR speaks for *you* and you stand behind the code, we don't care how it was produced. Every PR gets a thorough review regardless.

We have to move fast. The sea is moving under our feet.

**If something's missing, that's an opportunity.** No AGENTS.md? No usage_rules? Something feels like it should exist but doesn't? Open a PR or file an issue. The repo is days old -- there's a lot to build and we want your input on what it becomes.

## Repository Structure

This is a monorepo. The main components are:

- **`loomkin-server/`** — The Elixir/Phoenix server (the core of the project)
- **`apps/`** — Client applications (desktop, mobile) — added in later phases
- **`packages/`** — Shared JS/TS libraries — added in later phases
- **`services/`** — Polyglot backend services — added in later phases

All `mix` commands should be run from within the `loomkin-server/` directory, or use the `make` targets from the repo root.

## Prerequisites

Before you start, make sure you have:

- **Elixir 1.18+** (with Erlang/OTP 27+) -- we use [mise](https://mise.jdx.dev/) for version management (versions are pinned in `.mise.toml`)
- **PostgreSQL 17** -- running locally or via Docker
- **Node.js 22** -- for asset compilation
- **pnpm 10** -- for JS workspace management (installed via mise)

You can verify your setup with:

```bash
elixir --version
psql --version
node --version
pnpm --version
```

## Getting Set Up

1. **Fork and clone the repo:**

   ```bash
   git clone https://github.com/<your-username>/loomkin.git
   cd loomkin
   ```

2. **Install tooling and project dependencies:**

   ```bash
   make setup
   ```

3. **Start the dev server:**

   ```bash
   make dev
   ```

   The app runs at [http://localhost:4200](http://localhost:4200) or [http://loom.test:4200](http://loom.test:4200) (configured automatically by `make setup`).

4. **Run the test suite:**

   ```bash
   make test
   ```

   We have a large and growing test suite. Tests should all pass on a fresh setup. If something fails, check that PostgreSQL is running and your Elixir version meets the minimum.

5. **See all available make targets:**

   ```bash
   make help
   ```

## Development Workflow

### Branching

Create a branch from `main` with a descriptive name:

```bash
git checkout -b fix/agent-timeout-handling
git checkout -b feat/add-discord-adapter
git checkout -b docs/update-setup-instructions
```

Use prefixes like `fix/`, `feat/`, `docs/`, or `refactor/` to signal intent.

### Commits

We use [Conventional Commits](https://www.conventionalcommits.org). Every commit message must start with a type prefix:

```
feat: add keyboard shortcut for team switching
fix: resolve agent loop crash on empty tool response
docs: update setup instructions for PostgreSQL 14
refactor: simplify priority router classification logic
ci: pin action SHAs for supply chain security
test: add regression test for consensus quorum edge case
```

Valid types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`, `perf`, `revert`.

**Subject rules:**
- Must be **fully lowercase** -- no uppercase letters at all, including acronyms (write `ui` not `UI`, `api` not `API`)
- Max **100 characters** for the full header (type + subject)
- No period at the end

The PR title must also follow this format -- it becomes the squash-merge commit message on `main`.

### Git Hooks

We use [Lefthook](https://github.com/evilmartians/lefthook) to enforce formatting and commit message conventions locally. Install it once after cloning:

```bash
lefthook install
```

If you haven't run `make setup`, install lefthook first: `brew bundle` (it's in the `Brewfile`).

This installs two hooks:
- **pre-commit** -- runs `mix format --check-formatted` (inside `loomkin-server/`) and blocks if formatting is off
- **commit-msg** -- validates your commit message against the conventional commits rules

### Before You Commit

Always run the formatter:

```bash
cd loomkin-server && mix format
```

The project has a `.formatter.exs` that handles all formatting rules. If your editor supports it, enable format-on-save.

Run the tests to make sure nothing is broken:

```bash
cd loomkin-server && mix test
```

To run a specific test file or line:

```bash
cd loomkin-server && mix test test/loomkin/teams/agent_test.exs
cd loomkin-server && mix test test/loomkin/teams/agent_test.exs:42
```

## Submitting a Pull Request

1. Push your branch to your fork
2. Open a PR against `main` on [github.com/bleuropa/loomkin](https://github.com/bleuropa/loomkin)
3. Fill in a clear description of what your PR does and why
4. If it addresses an issue, reference it (e.g., "Closes #123")
5. Make sure CI passes -- we'll review from there

Keep PRs focused. One logical change per PR is easier to review than a grab bag of unrelated edits.

## Code Style

- Follow the existing patterns in the codebase
- Run `mix format` -- it's the single source of truth for formatting
- Use pattern matching over conditional logic where it makes sense
- Prefer functional components over LiveComponents
- Use LiveView streams for collections
- Keep modules focused and well-named

If you're unsure about a design decision, open an issue or ask on Discord before writing a lot of code. We'd rather help you find the right approach early.

## Testing Expectations

- **New features** should include tests
- **Bug fixes** should include a regression test when practical
- **Don't break existing tests** -- if a test needs updating because of your change, update it and explain why in the PR

We use `ExUnit` with the real database (no mocks for Ecto). Tests run in a sandbox, so they're isolated and can run concurrently.

## Where to Ask Questions

- **Discord:** [https://discord.gg/WUVneqArVD](https://discord.gg/WUVneqArVD) -- best for quick questions and discussion
- **GitHub Issues:** [github.com/bleuropa/loomkin/issues](https://github.com/bleuropa/loomkin/issues) -- best for bugs, feature requests, and proposals

## New Here?

Look for issues labeled **"good first issue"** -- these are scoped, well-defined tasks that are a great way to get familiar with the codebase. If one catches your eye, drop a comment and we'll help you get started.

---

Thanks for contributing. Every improvement matters, and we appreciate your time.
