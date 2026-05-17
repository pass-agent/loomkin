import React from "react";
import { Box, Text } from "ink";
import type { EpicCard } from "../stores/epicCardStore.js";

/**
 * Sticky in-chat card for a single live epic. Replaces the per-event
 * system-message firehose with one card per epic. Pause/cancel/open
 * action-hints are static for now — wiring is r14's work.
 */

interface Props {
  card: EpicCard;
  /** Override "now" for stable test snapshots. */
  now?: number;
}

const TOTAL_DOTS = 9;

/**
 * Hard-coded phase order matching `Loomkin.Orchestration.IssueOrchestrator`
 * — kept here so the card can render its 9-dot progress without a server
 * round-trip. Used only for visual progress; if the phase name doesn't
 * match the dots fall back to showing only the entered phases.
 */
const PHASE_ORDER = [
  "research",
  "plan",
  "plan_review",
  "design_review",
  "decompose",
  "implement",
  "validate_dod",
  "open_pr",
  "curate",
];

function progressIndex(phase: string | null): number {
  if (!phase) return -1;
  const idx = PHASE_ORDER.indexOf(phase);
  return idx;
}

function formatElapsed(card: EpicCard, now: number): string {
  const seconds = Math.max(0, Math.floor((now - card.started_at) / 1000));
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function statusColor(status: EpicCard["status"]): string {
  switch (status) {
    case "closed":
      return "green";
    case "failed":
      return "red";
    case "escalated":
      return "yellow";
    case "monitoring":
    default:
      return "cyan";
  }
}

export function OrchestrationEpicCard({ card, now = Date.now() }: Props) {
  const persona = card.current_persona;
  const idx = progressIndex(card.current_phase);
  const dots = Array.from({ length: TOTAL_DOTS }, (_, i) => (i <= idx ? "●" : "○")).join(" ");
  const elapsed = formatElapsed(card, now);
  const banner =
    card.status === "failed"
      ? " — failed"
      : card.status === "escalated"
        ? " — escalated (human attention needed)"
        : card.status === "closed"
          ? " — closed"
          : "";

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={statusColor(card.status)}
      paddingX={1}
      marginBottom={1}
    >
      <Box>
        <Text bold color={statusColor(card.status)}>
          {persona ? `${persona.icon} ${persona.name}` : "Orchestration"}
        </Text>
        {persona?.role_blurb ? <Text dimColor> · {persona.role_blurb}</Text> : null}
        <Text dimColor>{`  ${elapsed}${banner}`}</Text>
      </Box>

      <Box>
        <Text dimColor>Epic: </Text>
        <Text>{card.epic_id}</Text>
      </Box>

      <Box>
        <Text dimColor>Phase: </Text>
        <Text>{card.current_phase ?? "—"}</Text>
      </Box>

      <Box>
        <Text>{dots}</Text>
      </Box>

      <Box>
        <Text dimColor>Work units: </Text>
        <Text>{card.work_unit_count}</Text>
      </Box>

      <Box>
        <Text dimColor>Last: </Text>
        <Text wrap="truncate-end">{card.last_event_text ?? "—"}</Text>
      </Box>

      {card.diff_summaries.length > 0 ? (
        <Box>
          <Text dimColor>Diffs: </Text>
          <Text>{card.diff_summaries.length}</Text>
        </Box>
      ) : null}

      <Box>
        <Text dimColor>[p] pause [c] cancel [o] open dashboard</Text>
      </Box>
    </Box>
  );
}
