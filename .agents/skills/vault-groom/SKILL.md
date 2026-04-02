---
name: vault-groom
description: Audit and clean up knowledge base state — archive completed work, fix inconsistencies
allowed-tools:
  - vault_audit
  - vault_kanban
  - vault_update_entry
  - vault_search
  - vault_dashboard
  - ask_user
---

Run a health check on the knowledge base and fix issues.

## Audit

`vault_audit(scope: "full")` — get the full quality report.

## Check Task Board

`vault_kanban(action: "list", filter_column: "done")` — find completed tasks ready for archive.
`vault_kanban(action: "list", filter_column: "in_progress")` — check for stale items (no activity in 7+ days).

## Check Temporal Entries

`vault_search(query: "*", entry_type: "checkin")` — find checkins older than 30 days for archiving.

## Present Findings

Format as a structured report:
- Task issues (missing metadata, stale items)
- Completed tasks ready to archive
- Old checkins ready to archive
- Quality issues from vault_audit
- OKR/milestone status inconsistencies

## Interactive Fix

Use `ask_user` to confirm each category of fix:
- "Archive these X completed tasks?"
- "Archive these Y old checkins?"
- "Fix these Z metadata issues?"

## Apply Fixes

- Archive tasks: `vault_kanban(action: "archive")`
- Archive checkins: `vault_update_entry(status: "archived")` for each
- Fix metadata: `vault_update_entry(frontmatter_updates: "...")` for each

## Refresh

`vault_dashboard(dashboard_type: "index")` after all fixes.
