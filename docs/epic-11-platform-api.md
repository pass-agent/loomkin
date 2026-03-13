# Epic 11: Platform API (Descoped — On Hold)

## Status: ON HOLD

This epic was originally scoped to add CLI, REST API, and webhooks to make Loomkin programmable from the outside. After architectural review, the priority shifted:

- **Loomkin stays a local-first agent coding tool** — not a SaaS platform or embeddable library
- **The vault primitive (Epic 12) is the real blocker** — it unlocks non-coding use cases (novels, docs, research) without requiring API surface
- **CLI/REST/Webhooks are future work** — only needed if Loomkin is deployed as a web service or needs programmatic access from external systems

## What Was Planned

1. API Key authentication (`lmk_` prefixed, SHA-256 hashed)
2. REST API for sessions, teams, agents, messages
3. SSE streaming endpoint for real-time events
4. Webhook event delivery (Oban-backed)
5. CLI via Owl + Burrito binary
6. Rate limiting via Hammer

## When to Revisit

- If Loomkin is deployed to the web and needs multi-user access
- If non-Elixir applications need to interact with Loomkin
- If CI/CD pipelines need to trigger agent operations
- If another Elixir app needs Loomkin as a dependency (consider hex package extraction at that point)

## Original Plan

The full original plan is preserved in git history. Key architectural decisions documented there remain valid if this work is picked up later.
