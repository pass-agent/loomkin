import React from "react";
import { Box, Text, useInput } from "ink";
import type { EpicCard } from "../stores/epicCardStore.js";
import { useChannelStore } from "../stores/channelStore.js";

/**
 * Sticky in-chat card for a single live epic. Replaces the per-event
 * system-message firehose with one card per epic.
 *
 * Keyboard steering (r14):
 *   p — pause   c — cancel   r — resume (only when paused)
 *   a — approve x — reject   (only when awaiting_approval)
 *   o — open dashboard (TODO: not wired yet)
 *
 * Each keystroke is sent as an inline CLI command through the active
 * session channel. The `SessionBridge` on the server interprets it
 * (e.g. `/orchestration pause <epic_id>`).
 */

interface Props {
  card: EpicCard;
  /** Override "now" for stable test snapshots. */
  now?: number;
  /**
   * Only the focused card listens for keyboard input. Tests can leave this
   * unset (defaults to false) to avoid raw-mode initialization in non-TTY
   * environments — the keystroke handler under test is invoked directly.
   */
  isFocused?: boolean;
  /**
   * Override hook for tests — bypasses the live channel store and lets a
   * test inject a spy. In production the default `defaultSendCommand` pushes
   * onto the active session channel.
   */
  onCommand?: (command: string) => void;
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

/**
 * Format a USD cost into "$0.43" / "$12.00". Returns "—" for nullish.
 * Exported for tests.
 */
export function formatCost(cost: number | undefined | null): string {
  if (typeof cost !== "number" || !Number.isFinite(cost)) return "—";
  if (cost === 0) return "$0.00";
  // Show 4 digits for tiny costs so we don't render "$0.00" for a real spend.
  const digits = cost < 0.01 ? 4 : 2;
  return `$${cost.toFixed(digits)}`;
}

/**
 * Format an ETA in seconds into "3m 12s" / "45s". Returns "—" for nullish.
 * Exported for tests.
 */
export function formatEta(seconds: number | undefined | null): string {
  if (typeof seconds !== "number" || !Number.isFinite(seconds) || seconds < 0) {
    return "—";
  }
  const total = Math.floor(seconds);
  const minutes = Math.floor(total / 60);
  const secs = total % 60;
  return minutes > 0 ? `${minutes}m ${secs}s` : `${secs}s`;
}

function statusColor(status: EpicCard["status"]): string {
  switch (status) {
    case "closed":
      return "green";
    case "failed":
      return "red";
    case "escalated":
      return "yellow";
    case "paused":
      return "yellow";
    case "cancelled":
      return "gray";
    case "awaiting_approval":
      return "magenta";
    case "monitoring":
    default:
      return "cyan";
  }
}

/**
 * Default command transport — pushes a `send_message` frame onto the
 * active session channel so the server's SessionBridge parses it as a
 * CLI command. We use the channel directly (instead of `useSessionChannel`)
 * to keep this component decoupled from React-tree wiring.
 */
function defaultSendCommand(command: string): void {
  const ch = useChannelStore.getState().getChannel();
  if (!ch) return;
  ch.push("send_message", { content: command });
}

/**
 * Pure (test-friendly) translator from a key press + card state into the
 * inline CLI command (or `null` if the key has no meaning in this state).
 * Exported so tests can hammer it without mounting Ink.
 */
export function commandForKey(
  key: string,
  card: Pick<EpicCard, "epic_id" | "status">,
): string | null {
  switch (key) {
    case "p":
      if (card.status === "monitoring" || card.status === "awaiting_approval") {
        return `/orchestration pause ${card.epic_id}`;
      }
      return null;
    case "c":
      if (card.status !== "closed" && card.status !== "failed" && card.status !== "cancelled") {
        return `/orchestration cancel ${card.epic_id}`;
      }
      return null;
    case "r":
      if (card.status === "paused") {
        return `/orchestration resume ${card.epic_id}`;
      }
      return null;
    case "a":
      if (card.status === "awaiting_approval") {
        return `/orchestration approve ${card.epic_id}`;
      }
      return null;
    case "x":
      if (card.status === "awaiting_approval") {
        return `/orchestration reject ${card.epic_id}`;
      }
      return null;
    case "o":
      // TODO(r14+): open the LiveView dashboard for this epic. Wire this
      // once we agree on an OS-open helper (likely shells out to `open`
      // on macOS / `xdg-open` on linux).
      return null;
    default:
      return null;
  }
}

/**
 * Tiny sub-component that owns the `useInput` hook subscription. We isolate
 * the hook in its own component (and only mount it when `isFocused` is true)
 * so the parent card component remains a pure renderer — callers (including
 * tests) can invoke `OrchestrationEpicCard(...)` as a function without
 * dragging Ink's stdin context into the call.
 */
function SteeringInput({
  card,
  onCommand,
}: {
  card: EpicCard;
  onCommand: (command: string) => void;
}) {
  useInput((input) => {
    const command = commandForKey(input, card);
    if (command) onCommand(command);
  });
  return null;
}

export function OrchestrationEpicCard({
  card,
  now = Date.now(),
  isFocused = false,
  onCommand,
}: Props) {
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
          : card.status === "paused"
            ? " — paused"
            : card.status === "cancelled"
              ? " — cancelled"
              : card.status === "awaiting_approval"
                ? " — awaiting approval"
                : "";

  const isAwaiting = card.status === "awaiting_approval";

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={statusColor(card.status)}
      paddingX={1}
      marginBottom={1}
    >
      {isFocused ? <SteeringInput card={card} onCommand={onCommand ?? defaultSendCommand} /> : null}
      <Box>
        <Text bold color={statusColor(card.status)}>
          {persona ? `${persona.icon} ${persona.name}` : "Orchestration"}
        </Text>
        {persona?.role_blurb ? <Text dimColor> · {persona.role_blurb}</Text> : null}
        <Text dimColor>{`  ${elapsed}${banner}`}</Text>
      </Box>

      <Box>
        <Text dimColor>cost: </Text>
        <Text>{formatCost(card.cost_usd)}</Text>
        <Text dimColor> · eta: </Text>
        <Text>{formatEta(card.eta_seconds)}</Text>
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

      {isAwaiting ? (
        <Box>
          <Text color="magenta">[a] approve [x] reject</Text>
        </Box>
      ) : null}

      <Box>
        <Text dimColor>
          {card.status === "paused"
            ? "[r] resume [c] cancel [o] open dashboard"
            : isAwaiting
              ? "[p] pause [c] cancel [o] open dashboard"
              : "[p] pause [c] cancel [o] open dashboard"}
        </Text>
      </Box>
    </Box>
  );
}
