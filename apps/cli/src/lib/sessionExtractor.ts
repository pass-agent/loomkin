import { sessionStore } from "../stores/sessionStore.js";
import { saveMemory, getMemoryDir } from "./memory.js";
import { join } from "path";
import { existsSync, readFileSync } from "fs";

const EXTRACTION_TOKEN_THRESHOLD = 30_000;
const EXTRACTION_TOOL_CALL_THRESHOLD = 3;

export function shouldExtract(): boolean {
  const s = sessionStore.getState();
  const currentTokens = s.totalInputTokens + s.totalOutputTokens;
  return (
    currentTokens - s.lastExtractionTokenCount >= EXTRACTION_TOKEN_THRESHOLD &&
    s.toolCallsSinceExtraction >= EXTRACTION_TOOL_CALL_THRESHOLD &&
    !s.extractionInProgress
  );
}

export async function runBackgroundExtraction(sessionId: string): Promise<void> {
  const store = sessionStore.getState();
  store.setExtractionInProgress(true);

  try {
    // Build a summary from the last 20 assistant messages
    const recentMessages = store.messages
      .filter((m) => m.role === "assistant")
      .slice(-20)
      .map((m) => m.content ?? "")
      .join("\n\n");

    const wordCount = recentMessages.split(/\s+/).filter(Boolean).length;
    const summary = `Session ${sessionId} context summary (${wordCount} words of recent output):\n\n${recentMessages.slice(0, 1500)}`;

    // Save as session memory with frontmatter
    const memoryName = `session-${sessionId}`;
    saveMemory(memoryName, "session", summary);

    // Record extraction point
    const currentTokens = store.totalInputTokens + store.totalOutputTokens;
    sessionStore.getState().recordExtraction(currentTokens);
  } finally {
    sessionStore.getState().setExtractionInProgress(false);
  }
}

/**
 * Load an existing session memory file for a given session id.
 * Returns the memory content if found, null otherwise.
 */
export function loadSessionMemory(sessionId: string): string | null {
  // safeName logic mirrors memory.ts: lowercase, replace non-alphanumeric with '-', trim, slice(0, 60)
  const raw = `session-${sessionId}`;
  const safeName = raw
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
  const filePath = join(getMemoryDir(), `${safeName}.md`);
  if (!existsSync(filePath)) return null;

  try {
    const content = readFileSync(filePath, "utf-8");
    // Strip YAML frontmatter and return body
    const match = content.match(/^---\n[\s\S]*?\n---\n([\s\S]*)$/);
    return match ? match[1].trim() : content.trim();
  } catch {
    return null;
  }
}
