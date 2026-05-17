/**
 * Format an `orchestration_phase` channel payload into a terse system-role
 * message that fits cleanly in the conversation feed.
 *
 * Returns `null` to skip rendering (e.g. unknown event shapes that aren't
 * worth surfacing).
 *
 * Conventions:
 *   ⇢ <phase>          for forward phase entry
 *   ✓ <phase>           for pass / success
 *   ✗ <phase>           for fail
 *   ▲ escalated         for human-escalation events
 *   ⇡ knowledge:<n>     for curator extractions
 */
export function formatOrchestrationPhase(payload: {
  subtype?: string;
  event?: unknown;
  epic_id?: string;
  work_unit_id?: string;
}): string | null {
  const { subtype, event } = payload;
  const scope = scopeLabel(payload);

  // Tuple events come over the channel as Elixir tuples; Phoenix encodes them
  // as arrays. We accept both arrays and plain string events.
  if (Array.isArray(event)) {
    const [tag, ...rest] = event as [string, ...unknown[]];

    switch (tag) {
      case "phase_entered": {
        const phase = String(rest[0] ?? "");
        return `${scope}⇢ ${phase}`;
      }
      case "gate_verdict": {
        const [gate, verdict, count] = rest as [string, string, number];
        const glyph = verdict === "pass" ? "✓" : "✗";
        return `${scope}${glyph} ${gate} · ${count} reviewer${count === 1 ? "" : "s"}`;
      }
      case "escalated":
        return `${scope}▲ escalated (3-iteration cap exceeded)`;
      case "fail": {
        const [where, reason] = rest as [string, unknown];
        return `${scope}✗ ${where} failed: ${stringify(reason)}`;
      }
      case "review_pass": {
        return `${scope}✓ review passed`;
      }
      case "review_fail": {
        return `${scope}✗ review failed`;
      }
      case "retry": {
        const [retryState, _reason] = rest as [string, unknown];
        return `${scope}↻ retry → ${retryState}`;
      }
      case "validate_pass":
        return `${scope}✓ validate`;
      case "validate_fail":
        return `${scope}✗ validate`;
      case "commit_done": {
        const sha = String(rest[0] ?? "");
        return `${scope}✓ commit ${sha.slice(0, 12)}`;
      }
      default:
        return null;
    }
  }

  if (typeof event === "string") {
    switch (event) {
      case "created":
        return `${scope}⇢ created`;
      case "started":
        return `${scope}⇢ started`;
      case "implement_complete":
        return `${scope}✓ implement`;
      case "completed":
        return `${scope}✓ completed`;
      case "failed":
        return `${scope}✗ failed`;
      case "closed":
        return `${scope}✓ closed`;
      default:
        return `${scope}· ${event}`;
    }
  }

  if (subtype === "knowledge") {
    return `${scope}⇡ knowledge fact added`;
  }

  return null;
}

function scopeLabel(payload: {
  subtype?: string;
  epic_id?: string;
  work_unit_id?: string;
}): string {
  if (payload.work_unit_id) {
    return `[wu:${payload.work_unit_id.slice(0, 6)}] `;
  }
  if (payload.epic_id) {
    return `[epic:${payload.epic_id.slice(0, 6)}] `;
  }
  if (payload.subtype) {
    return `[${payload.subtype}] `;
  }
  return "";
}

function stringify(v: unknown): string {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}
