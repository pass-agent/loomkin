---
name: vault-dashboard
description: Manually refresh the knowledge base dashboard
allowed-tools:
  - vault_dashboard
  - vault_update_entry
  - vault_search
---

Refresh the main dashboard entry with current state.

## Index Dashboard

1. `vault_dashboard(dashboard_type: "index")` — get full dashboard data
2. Search for the current Index entry: `vault_search(query: "Index", entry_type: "topic")`
3. If it exists, `vault_update_entry(path: "Index.md", content: "{formatted dashboard}")` — rewrite with fresh data
4. If it doesn't exist, create it as a topic entry

## Updates Hub

1. `vault_dashboard(dashboard_type: "updates_hub")` — get checkin summary
2. Update or create the updates index entry

## Report

Confirm which dashboards were refreshed and any notable changes (new completions, at-risk items, etc.).
