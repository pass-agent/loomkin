---
name: vault-okr
description: View, update, review, or create OKR cycles
allowed-tools:
  - vault_search
  - vault_create_entry
  - vault_update_entry
  - vault_dashboard
  - ask_user
---

Manage Objectives and Key Results. Parse arguments to determine subcommand:

## view (default)

`vault_search(query: "*", tags: ["okr"])` — read all active OKR entries.
Present a formatted summary with objectives, key results, current values, targets,
and status indicators (On Track >= 70%, At Risk 40-70%, Off Track < 40%, Completed = 100%).

## update

For each selected OKR and key result:
- Show current value and target
- `ask_user` for new value
- Calculate status
- `vault_update_entry` with new frontmatter values
- Add a weekly check-in section to the OKR entry content

## review

Display current status (same as view), then for each OKR:
- Ask for key result updates
- Ask for blockers
- Ask for wins to note
- Update entries and check if milestones should change

## new

Determine next cycle number from existing OKRs.
Ask for cycle dates, objectives, key results per scope.
`vault_create_entry(entry_type: "note", tags: ["okr"], ...)` for each scope.
Update the OKR hub entry to list the new cycle.

## retro

Display final status, prompt for retrospective content per OKR
(what worked, what didn't, what to carry forward).
Update OKR entries with retrospective section, mark as completed.
