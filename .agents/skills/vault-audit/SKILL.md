---
name: vault-audit
description: Run a quality audit on the knowledge base
allowed-tools:
  - vault_audit
  - vault_update_entry
  - ask_user
---

Run a quality audit. Parse arguments for scope:
- No args or "full": `vault_audit(scope: "full")`
- "links": `vault_audit(scope: "links")`
- "temporal": `vault_audit(scope: "temporal")`
- "frontmatter": `vault_audit(scope: "frontmatter")`
- "structure": `vault_audit(scope: "structure")`

Present the report to the user organized by severity (Critical, Warning, Info).

If the user wants fixes applied:
- For auto-fixable issues: `vault_audit(scope: "...", fix: true)`
- For judgment calls: walk through each with `ask_user`
