---
name: vault-prep
description: Generate a pre-meeting agenda with context gathered from the knowledge base
allowed-tools:
  - vault_create_entry
  - vault_update_entry
  - vault_search
  - vault_kanban
  - vault_dashboard
  - ask_user
---

Create or update a meeting prep file with topics and auto-gathered context.

## Identify Contributor

Who is adding topics? Look for @mentions or ask.

## Check for Existing Prep

`vault_search(query: "prep", entry_type: "meeting")` filtered to today's date.

- **If exists**: APPEND MODE — add this person's topics to the existing prep
- **If not**: CREATE MODE — gather full context and create new prep

## Gather Context (CREATE MODE only)

1. **Recent meetings**: `vault_search(query: "*", entry_type: "meeting")` last 3
   - Extract discussion topics, open action items, decisions
2. **Open follow-ups**: `vault_kanban(action: "list")` filtered to items with meeting sources
3. **Recent checkins**: `vault_search(query: "*", entry_type: "checkin")` since last meeting
   - Summarize as "async updates" — no need to rehash in the meeting
4. **At-risk OKRs**: `vault_search(query: "*", tags: ["okr"])` — check frontmatter for status
5. **Upcoming milestones**: `vault_search(query: "milestone", tags: ["in-progress"])`

## Parse Topics

From user input, extract:
- Topics they want to discuss
- Decisions that need to be made
- Questions they have

## Create/Update Entry

**CREATE**: `vault_create_entry(entry_type: "meeting", ...)` with prep content, include `prep_generated: true` and `contributors: ["{person}"]` in extra_frontmatter

**APPEND**: `vault_update_entry(append: "{person}'s topics:\n- [ ] Topic 1\n- [ ] Topic 2")`
Also update `contributors` list in frontmatter.

Check for duplicate topics across contributors — note "(Also raised by {other person})" if similar.

## Report

CREATE: Topics added, context gathered (follow-ups count, async updates, at-risk items)
APPEND: Topics added, existing agenda summary, current contributors list
