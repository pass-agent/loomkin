import React, { useState } from "react";
import { Box, Text, useInput } from "ink";

/**
 * Payload pushed by the server on the `orchestration_diff` channel event.
 * Shape mirrors `Loomkin.Orchestration.Diff.capture/2` on the server.
 */
export interface DiffPayload {
  work_unit_id?: string;
  sha?: string;
  stats?: {
    additions?: number;
    deletions?: number;
    files?: number;
  };
  files?: Array<{
    path?: string;
    additions?: number;
    deletions?: number;
  }>;
  patch_excerpt?: string;
}

export interface DiffSummaryLine {
  /** Short sha or empty string */
  sha: string;
  /** Total additions across the commit */
  additions: number;
  /** Total deletions across the commit */
  deletions: number;
  /** Number of files touched */
  files: number;
}

/**
 * Distil a {@link DiffPayload} down to the one-line collapsed-state summary.
 * Pure so it can be unit-tested without rendering ink.
 */
export function summarize(payload: DiffPayload): DiffSummaryLine {
  const stats = payload.stats ?? {};
  return {
    sha: typeof payload.sha === "string" ? payload.sha.slice(0, 7) : "",
    additions: stats.additions ?? 0,
    deletions: stats.deletions ?? 0,
    files: stats.files ?? 0,
  };
}

/**
 * Render the collapsed summary as plain text — useful both for the
 * component's one-line form and for fallback contexts (e.g. system
 * message in the conversation feed when no rich renderer is available).
 *
 * Uses ASCII +/- so it survives terminals without unicode minus.
 */
export function formatSummary(payload: DiffPayload): string {
  const s = summarize(payload);
  const filesLabel = s.files === 1 ? "file" : "files";
  const shaSuffix = s.sha ? ` · ${s.sha}` : "";
  return `+${s.additions} −${s.deletions} across ${s.files} ${filesLabel}${shaSuffix}`;
}

export interface DiffPreviewProps {
  payload: DiffPayload;
  /**
   * Capture the `e` key to expand/collapse. Tests pass `false` so the hook
   * isn't installed; component consumers can also pass false if they want
   * to manage the expanded state externally.
   *
   * @default true
   */
  interactive?: boolean;
  /**
   * Optional controlled expanded state. When provided, `interactive` is
   * ignored — the parent owns the toggle.
   */
  expanded?: boolean;
}

/**
 * Inline diff preview rendered in the CLI conversation feed.
 *
 * Collapsed (default) shows a single line: `+N −M across K files · sha`.
 * When expanded (press `e`) the per-file breakdown and the first ~80 lines
 * of the unified diff are shown.
 */
export function DiffPreview({ payload, interactive = true, expanded }: DiffPreviewProps) {
  const [open, setOpen] = useState(false);
  const isOpen = expanded ?? open;

  useInput(
    (input) => {
      if (input === "e") {
        setOpen((v) => !v);
      }
    },
    { isActive: interactive && expanded === undefined },
  );

  return (
    <Box flexDirection="column" marginTop={1}>
      <Box>
        <Text color="green">+{summarize(payload).additions}</Text>
        <Text> </Text>
        <Text color="red">−{summarize(payload).deletions}</Text>
        <Text color="gray"> across {summarize(payload).files} </Text>
        <Text color="gray">{summarize(payload).files === 1 ? "file" : "files"}</Text>
        {summarize(payload).sha ? <Text color="gray"> · {summarize(payload).sha}</Text> : null}
        {!isOpen && interactive && expanded === undefined ? (
          <Text color="gray" dimColor>
            {"  (e to expand)"}
          </Text>
        ) : null}
      </Box>
      {isOpen ? (
        <Box flexDirection="column" marginTop={1}>
          {(payload.files ?? []).map((f) => (
            <Box key={f.path ?? Math.random().toString(36)}>
              <Text color="green">+{f.additions ?? 0}</Text>
              <Text> </Text>
              <Text color="red">−{f.deletions ?? 0}</Text>
              <Text> {f.path ?? "(unknown path)"}</Text>
            </Box>
          ))}
          {payload.patch_excerpt ? (
            <Box flexDirection="column" marginTop={1}>
              <Text color="gray" dimColor>
                patch excerpt:
              </Text>
              <Text>{payload.patch_excerpt}</Text>
            </Box>
          ) : null}
        </Box>
      ) : null}
    </Box>
  );
}
