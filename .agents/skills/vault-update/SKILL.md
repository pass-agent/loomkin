---
name: vault-update
description: Process a work brain-dump and sync progress across the knowledge base
allowed-tools:
  - vault_kanban
  - vault_update_entry
  - vault_search
  - vault_dashboard
  - ask_user
---

Process a work update and sync changes to kanban, milestones, and OKRs.

## Parse Input

Identify:
- **Completions**: Tasks finished
- **Progress**: Work advancing existing items
- **Blockers**: Things preventing progress
- **New work**: Items not yet tracked

## Match to Existing Items

For each item mentioned:
1. `vault_kanban(action: "search", search_term: "{item}")` — check task board
2. `vault_search(query: "{item}")` — broader search for related entries

If match confidence is low, use `ask_user`: "Is this the same as [existing item]?"

## Apply Updates

- Completions: `vault_kanban(action: "complete", ...)`
- Progress: `vault_kanban(action: "move", column: "in_progress", ...)` if not already
- Blockers: `vault_update_entry` on relevant entries to add blocker tag
- New items: `ask_user` which project/priority, then `vault_kanban(action: "add", ...)`

## Refresh

`vault_dashboard(dashboard_type: "index")` to regenerate the full dashboard.

Report: what was completed, updated, added, and any items needing clarification.
