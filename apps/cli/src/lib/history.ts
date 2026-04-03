import { readFileSync, mkdirSync } from "fs";
import { dirname } from "path";
import { getHistoryPath } from "./config.js";

const MAX_HISTORY = 500;

/**
 * Load history from disk. Returns an empty array on any error.
 * Uses synchronous I/O — called once before the TUI renders.
 */
export function loadHistory(): string[] {
  try {
    const content = readFileSync(getHistoryPath(), "utf-8");
    const parsed = JSON.parse(content);
    if (Array.isArray(parsed)) {
      return (parsed as unknown[]).filter((e): e is string => typeof e === "string").slice(-MAX_HISTORY);
    }
    return [];
  } catch {
    return [];
  }
}

/**
 * Save history to disk. Fire-and-forget — never blocks message submission.
 */
export function saveHistory(entries: string[]): void {
  const path = getHistoryPath();
  const trimmed = entries.slice(-MAX_HISTORY);
  const json = JSON.stringify(trimmed, null, 2);

  try {
    mkdirSync(dirname(path), { recursive: true });
  } catch {
    // ignore
  }

  // Async write via Bun — fire and forget
  Bun.write(path, json).catch(() => {
    // Swallow errors — history persistence is best-effort
  });
}

/**
 * Append an entry, deduplicating consecutive identical entries, trimmed to MAX_HISTORY.
 */
export function appendHistory(current: string[], entry: string): string[] {
  const trimmed = entry.trim();
  if (!trimmed) return current;

  // Suppress consecutive duplicates
  if (current.length > 0 && current[current.length - 1] === trimmed) {
    return current;
  }

  return [...current, trimmed].slice(-MAX_HISTORY);
}
