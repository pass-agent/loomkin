---
name: vault-checkin
description: Log a daily work check-in — records what was accomplished and syncs to task board
allowed-tools:
  - vault_create_entry
  - vault_update_entry
  - vault_kanban
  - vault_dashboard
  - ask_user
---

Log what the user worked on today.

## Identify Who

Look for indicators: "@brett", "@brandon", name mentions, or context clues.
If unclear, use `ask_user` to confirm.

## Parse Input

Extract:
- **Work items**: Things accomplished or worked on
- **Blockers**: Anything preventing progress (optional)
- **Notes**: Additional context or thoughts (optional)

## Create Check-in

`vault_create_entry(entry_type: "checkin", entry_date: "{today}", author: "{person}", ...)`

Content should include work items as a bulleted list, blockers section, and notes section.

If a checkin already exists for this person today, use `vault_update_entry` to append.

## Match to Kanban

For each work item that sounds like a completion:
1. `vault_kanban(action: "search", search_term: "{work_item}")` to find matching tasks
2. If a match has high confidence (similarity > 0.5), offer to mark complete
3. If uncertain, use `ask_user`: "Is '{work item}' the same as '{kanban task}'?"
4. Complete confirmed matches: `vault_kanban(action: "complete", task_id: "...")`

## Refresh

`vault_dashboard(dashboard_type: "activity")` to update the dashboard.

Report: checkin file created, work items recorded, kanban matches found/completed.
