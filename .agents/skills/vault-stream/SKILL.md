---
name: vault-stream
description: Capture a stream idea or guest profile for content planning
allowed-tools:
  - vault_create_entry
  - vault_search
  - vault_link
  - ask_user
---

Smart capture for content/show planning. Detect type from input:

**Guest profile** (input is about a person):
- Names someone specific
- Describes who they are, what they've built
- Mentions "guest", "have on", "should interview"

Action: `vault_create_entry(entry_type: "guest_profile", ...)`

**Stream idea** (input is about a topic/concept):
- Describes what the episode would be about
- Mentions a format (interview, vibe coding, demo, news)
- Has talking points

Action: `vault_create_entry(entry_type: "stream_idea", ...)`

When ambiguous (just names a person with no clear topic), default to guest profile.

## Guest Profiles

Extract: name, about, why they'd be good, relationship type (personal/network/cold), contact info, potential topics.

## Stream Ideas

Extract: topic, format, potential guest, planned date if mentioned.

## Link

Link to the parent project entry for the show via `vault_link(link_type: "parent")`.

Check for duplicates: `vault_search(query: "{name or topic}")` — if similar exists, suggest updating instead.
