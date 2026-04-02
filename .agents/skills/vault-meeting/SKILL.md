---
name: vault-meeting
description: Process a meeting transcript — extract decisions, action items, and key discussion points into structured vault entries
allowed-tools:
  - vault_create_entry
  - vault_update_entry
  - vault_search
  - vault_link
  - vault_kanban
  - vault_dashboard
  - decision_log
  - fetch_content
  - context_offload
  - ask_user
---

Process a meeting transcript and extract structured information into the knowledge base.

## Step 0: Get the Transcript

Determine where the transcript is:

- **Pasted directly**: Use the text from the user's message
- **Google Drive link or file ID**: `fetch_content(source: "google_drive", identifier: "{file_id}")`
- **URL**: `fetch_content(source: "url", identifier: "{url}")`
- **Local file reference**: Use `vault_read` or `file_read` as appropriate

If the user says something like "process the meeting from Drive" without a specific file, use `ask_user` to get the file ID or link.

## Step 1: Check for Prep

Search for a prep file matching the meeting date:
`vault_search(query: "prep", entry_type: "meeting", tags: ["prep"])`

If prep exists:
- Read it to understand the planned agenda
- Track which topics get covered during processing
- You will mark covered topics and report coverage at the end

## Step 2: Handle Long Transcripts

If the transcript is very long (appears to be 20+ minutes of conversation), offload it to a context keeper:
`context_offload(topic: "meeting-transcript-{date}", content: ...)`

This preserves the full transcript at high fidelity without consuming your context window.

## Step 3: Analyze the Transcript

Read through and identify:

**Attendees** — who spoke in the meeting

**Decisions** — commitments to a course of action. Look for:
- "Let's go with...", "We'll do...", "We decided..."
- Choosing between alternatives
- Agreeing on a direction

For each decision, assess:
- Who proposed it (who said "I think we should..." or "What if we...")
- Who decided (who gave final approval — "Sounds good", "Let's do it")
- Scope: company | product | project
- Reversibility: one-way (hard to undo — hiring, equity, pivots) | two-way (easy to change — features, tools)

**Action items** — be thorough. Look for ALL of these patterns:
- Explicit: "[Person] will...", "Can you...", "Take care of..."
- Volunteering: "I'll handle that", "Let me do...", "I can take..."
- Implied: If someone says they'll improve/fix/create something, that is a task
- Follow-ups: Items needing attention even without explicit assignment

**Key discussion points** — topics that got meaningful airtime

**Summary** — 2-3 sentence overview

## Step 4: Redaction Judgment

This is a shared company vault. Apply judgment about what belongs in shared records.

**Auto-redact** (do it, no confirmation needed):
- Phone numbers, addresses, SSNs
- Financial figures (salaries, investment amounts)
- Passwords, API keys

**Flag for user confirmation** (use `ask_user`):
- Explicit removal requests ("off the record", "don't add that")
- Personal asides clearly unrelated to work

**Omit entirely** (don't even flag):
- HR/personnel matters — note "Personnel discussion - details in private records"
- Individual criticism of team members

When redacting, think holistically about context. A single-line gap surrounded by reactions is worse than no redaction — remove the full exchange.

## Step 5: Create Entries

1. **Meeting note**: `vault_create_entry(entry_type: "meeting", ...)` with full extracted content
2. **Decision records**: For each decision:
   - `vault_create_entry(entry_type: "decision", ...)` — creates DR-YYYY-NNN automatically
   - `decision_log(node_type: "decision", ...)` — adds to the live decision graph with confidence score
   - `vault_link(source_path: meeting, target_path: decision, link_type: "decides")`
3. **Action items**: `vault_kanban(action: "add", ...)` for each task, linked to the meeting
4. **Atomic notes**: If discussion surfaced a reusable concept or strategy, create it as a note and link to the parent topic

## Step 6: Update Prep (if exists)

If a prep file existed:
- `vault_update_entry` to check off covered topics (`- [ ]` to `- [x]`)
- Count coverage: "Discussed X/Y agenda topics"
- Add `processed: true` to frontmatter

## Step 7: Refresh Dashboard

`vault_dashboard(dashboard_type: "activity")` then use the result to update the index entry.

## Step 8: Report

Summarize what was created:
- Meeting note path
- Decision records created (list with DR numbers)
- Action items added (count, grouped by assignee)
- Prep coverage (if applicable)
- Any flagged redactions that need review
