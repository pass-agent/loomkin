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
export interface OrchestrationPersona {
  name: string;
  icon: string;
  role_blurb?: string;
}

export function formatOrchestrationPhase(payload: {
  subtype?: string;
  event?: unknown;
  epic_id?: string;
  work_unit_id?: string;
  persona?: OrchestrationPersona;
}): string | null {
  const { subtype, event, persona } = payload;
  // When a persona is present we surface a named cast instead of the
  // anonymous [epic:abc] / [wu:xyz] scope tag — the persona already
  // identifies who is speaking.
  const scope = persona ? "" : scopeLabel(payload);

  // Tuple events come over the channel as Elixir tuples; Phoenix encodes them
  // as arrays. We accept both arrays and plain string events.
  if (Array.isArray(event)) {
    const [tag, ...rest] = event as [string, ...unknown[]];

    switch (tag) {
      case "phase_entered": {
        const phase = String(rest[0] ?? "");
        return withPersona(persona, `${scope}⇢ ${phase}`);
      }
      case "gate_verdict": {
        const [gate, verdict, count] = rest as [string, string, number];
        const glyph = verdict === "pass" ? "✓" : "✗";
        return withPersona(
          persona,
          `${scope}${glyph} ${gate} · ${count} reviewer${count === 1 ? "" : "s"}`,
        );
      }
      case "escalated":
        return withPersona(persona, `${scope}▲ escalated (3-iteration cap exceeded)`);
      case "fail": {
        const [where, reason] = rest as [string, unknown];
        return withPersona(persona, `${scope}✗ ${where} failed: ${stringify(reason)}`);
      }
      case "review_pass": {
        return withPersona(persona, `${scope}✓ review passed`);
      }
      case "review_fail": {
        return withPersona(persona, `${scope}✗ review failed`);
      }
      case "retry": {
        const [retryState, _reason] = rest as [string, unknown];
        return withPersona(persona, `${scope}↻ retry → ${retryState}`);
      }
      case "validate_pass":
        return withPersona(persona, `${scope}✓ validate`);
      case "validate_fail":
        return withPersona(persona, `${scope}✗ validate`);
      case "commit_done": {
        const sha = String(rest[0] ?? "");
        return withPersona(persona, `${scope}✓ commit ${sha.slice(0, 12)}`);
      }
      default:
        return null;
    }
  }

  if (typeof event === "string") {
    switch (event) {
      case "created":
        return withPersona(persona, `${scope}⇢ created`);
      case "started":
        return withPersona(persona, `${scope}⇢ started`);
      case "implement_complete":
        return withPersona(persona, `${scope}✓ implement`);
      case "completed":
        return withPersona(persona, `${scope}✓ completed`);
      case "failed":
        return withPersona(persona, `${scope}✗ failed`);
      case "closed":
        return withPersona(persona, `${scope}✓ closed`);
      default:
        return withPersona(persona, `${scope}· ${event}`);
    }
  }

  if (subtype === "knowledge") {
    return withPersona(persona, `${scope}⇡ knowledge fact added`);
  }

  return null;
}

function withPersona(persona: OrchestrationPersona | undefined, line: string): string {
  if (!persona) return line;
  return `${persona.icon} ${persona.name}: ${line}`;
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
