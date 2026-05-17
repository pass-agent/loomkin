import { createStore } from "zustand";
import { useStore } from "zustand";

/**
 * Live per-epic card state. Replaces the firehose of per-event system
 * messages with one sticky card per epic, updated incrementally as the
 * orchestration channel fires `orchestration_phase` / `orchestration_diff`
 * events.
 *
 * Contract with Agent A1's persona registry:
 *   payload.persona = {name: string, icon: string, role_blurb?: string}
 *   — may be absent during the transition; we handle that gracefully.
 */

export interface PersonaInfo {
  name: string;
  icon: string;
  role_blurb?: string;
}

export interface GateProgress {
  verdict: string;
  reviewers: number;
}

export interface DiffSummary {
  work_unit_id: string;
  stats: string;
}

export type EpicCardStatus = "monitoring" | "closed" | "failed" | "escalated";

export interface EpicCard {
  epic_id: string;
  current_phase: string | null;
  current_persona: PersonaInfo | null;
  work_unit_count: number;
  gate_progress: Record<string, GateProgress>;
  status: EpicCardStatus;
  last_event_text: string | null;
  diff_summaries: DiffSummary[];
  started_at: number;
}

export interface PhasePayload {
  subtype?: string;
  event?: unknown;
  epic_id?: string;
  work_unit_id?: string;
  persona?: PersonaInfo;
  // Optional diff payload shape (Agent A2 r13)
  diff?: { work_unit_id?: string; stats?: string };
  stats?: string;
}

export interface EpicCardState {
  cards: Record<string, EpicCard>;
  applyEvent: (payload: PhasePayload) => void;
  removeCard: (epic_id: string) => void;
  /** Test/debug helper — wipe all cards (does not run timers). */
  reset: () => void;
}

const REMOVE_AFTER_CLOSED_MS = 5_000;

function emptyCard(epic_id: string): EpicCard {
  return {
    epic_id,
    current_phase: null,
    current_persona: null,
    work_unit_count: 0,
    gate_progress: {},
    status: "monitoring",
    last_event_text: null,
    diff_summaries: [],
    started_at: Date.now(),
  };
}

/**
 * Pull the most descriptive scalar string out of a tuple event so we can
 * surface it on the `last_event_text` line without depending on the feed
 * renderer.
 */
function describeEvent(payload: PhasePayload): string | null {
  const { subtype, event, persona } = payload;
  const personaPrefix = persona ? `${persona.icon} ${persona.name}: ` : "";

  if (Array.isArray(event)) {
    const [tag, ...rest] = event as [string, ...unknown[]];
    switch (tag) {
      case "phase_entered":
        return `${personaPrefix}entered ${String(rest[0] ?? "")}`;
      case "gate_verdict": {
        const [gate, verdict, count] = rest as [string, string, number];
        return `${personaPrefix}${gate} ${verdict} (${count} reviewer${count === 1 ? "" : "s"})`;
      }
      case "escalated":
        return `${personaPrefix}escalated for human review`;
      case "fail": {
        const [where, _reason] = rest as [string, unknown];
        return `${personaPrefix}${where} failed`;
      }
      case "commit_done": {
        const sha = String(rest[0] ?? "").slice(0, 12);
        return `${personaPrefix}commit ${sha}`;
      }
      default:
        return `${personaPrefix}${tag}`;
    }
  }

  if (typeof event === "string") {
    return `${personaPrefix}${event}`;
  }

  if (subtype) return `${personaPrefix}${subtype} event`;
  return null;
}

export const epicCardStore = createStore<EpicCardState>((set, get) => ({
  cards: {},

  applyEvent: (payload) => {
    const epic_id = payload.epic_id;
    if (!epic_id) return;

    const subtype = payload.subtype;
    // Knowledge events are owned by the knowledge browser, not the card.
    if (subtype === "knowledge") return;

    // Orchestration diff payload — stubbed handler per A2 r13 contract.
    // We just push the summary; visual treatment is downstream.
    if (subtype === "orchestration_diff" || payload.diff) {
      const wu = payload.diff?.work_unit_id ?? payload.work_unit_id ?? "?";
      const stats = payload.diff?.stats ?? payload.stats ?? "";
      const current = get().cards[epic_id] ?? emptyCard(epic_id);
      set({
        cards: {
          ...get().cards,
          [epic_id]: {
            ...current,
            diff_summaries: [
              ...current.diff_summaries,
              { work_unit_id: String(wu), stats: String(stats) },
            ],
          },
        },
      });
      return;
    }

    const existing = get().cards[epic_id];
    const card: EpicCard = existing ? { ...existing } : emptyCard(epic_id);

    // Update persona whenever the payload carries one (transition-safe).
    if (payload.persona) {
      card.current_persona = payload.persona;
    }

    if (subtype === "epic") {
      const event = payload.event;

      if (Array.isArray(event)) {
        const [tag, ...rest] = event as [string, ...unknown[]];
        if (tag === "phase_entered") {
          card.current_phase = String(rest[0] ?? "");
        } else if (tag === "gate_verdict") {
          const [gate, verdict, count] = rest as [string, string, number];
          card.gate_progress = {
            ...card.gate_progress,
            [gate]: { verdict, reviewers: Number(count) || 0 },
          };
        } else if (tag === "escalated") {
          card.status = "escalated";
        }
      } else if (typeof event === "string") {
        switch (event) {
          case "created":
            // Initialize as monitoring (already the default for emptyCard).
            card.status = "monitoring";
            break;
          case "closed":
            card.status = "closed";
            break;
          case "failed":
            card.status = "failed";
            break;
          default:
            break;
        }
      }
    } else if (subtype === "work_unit") {
      // Any work-unit event implies progress — count unique work-unit ids if we
      // can, otherwise fall back to bumping the counter on "started" / "created".
      const wu = payload.work_unit_id;
      const isStarter =
        typeof payload.event === "string" &&
        (payload.event === "started" || payload.event === "created");
      if (isStarter && wu && !(card as unknown as { _seen?: Set<string> })._seen?.has(wu)) {
        const seen = (card as unknown as { _seen?: Set<string> })._seen ?? new Set<string>();
        seen.add(wu);
        (card as unknown as { _seen?: Set<string> })._seen = seen;
        card.work_unit_count = card.work_unit_count + 1;
      }
    }

    card.last_event_text = describeEvent(payload) ?? card.last_event_text;

    set({ cards: { ...get().cards, [epic_id]: card } });

    if (card.status === "closed") {
      const id = epic_id;
      setTimeout(() => {
        const latest = get().cards[id];
        if (latest && latest.status === "closed") {
          get().removeCard(id);
        }
      }, REMOVE_AFTER_CLOSED_MS);
    }
  },

  removeCard: (epic_id) => {
    const next = { ...get().cards };
    delete next[epic_id];
    set({ cards: next });
  },

  reset: () => set({ cards: {} }),
}));

export function useEpicCardStore<T>(selector: (s: EpicCardState) => T): T {
  return useStore(epicCardStore, selector);
}
