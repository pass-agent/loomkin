---
name: vault-ingest
description: Classify raw content and route it to the appropriate knowledge base location
allowed-tools:
  - vault_create_entry
  - vault_search
  - vault_link
  - vault_kanban
  - decision_log
  - ask_user
---

Analyze raw input and route to the right location in the knowledge base.

## Classify Content

Determine what this is:
- Strategy, process, or how-to: **note** (link to parent topic)
- Hub or organizing content: **topic**
- Product or brand information: **project**
- Person information: **person**
- A decision or commitment: **decision** (also log to decision graph)
- External reference: **source**
- A feature or product idea: **idea**

If the input contains multiple distinct concepts, extract each as a separate atomic entry.

## Check for Duplicates

`vault_search(query: "{key phrases from input}")` — if a similar entry exists, suggest updating it instead of creating a new one. Use `ask_user` to confirm.

## Create Entries

`vault_create_entry(entry_type: "{classified_type}", ...)` for each extracted concept.

For decisions, also create a decision graph node:
`decision_log(node_type: "decision", title: "...", confidence: ...)`

## Link

- Link new notes to parent topics via `vault_link(link_type: "parent")`
- Link related entries via `vault_link(link_type: "related")`
- Extract action items to `vault_kanban(action: "add", ...)`

Report: files created with paths, topics linked, action items added.
