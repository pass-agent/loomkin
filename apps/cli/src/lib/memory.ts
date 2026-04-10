import { readFileSync, writeFileSync, readdirSync, unlinkSync, mkdirSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

export interface MemoryEntry {
  name: string;
  type: string;
  content: string;
  filePath: string;
  scope: "global" | "project" | "agent";
  agentName?: string;
}

const MAX_PROMPT_CHARS = 2000;

export function getGlobalMemoryDir(): string {
  return join(homedir(), ".loomkin", "memory");
}

/** Backward-compat alias. */
export function getMemoryDir(): string {
  return getGlobalMemoryDir();
}

export function getProjectMemoryDir(cwd?: string): string {
  return join(cwd ?? process.cwd(), ".loomkin", "memory");
}

export function getAgentMemoryDir(agentName: string): string {
  // Sanitize agentName to prevent path traversal
  const safe =
    agentName
      .replace(/[^a-zA-Z0-9_-]/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 60) || "unknown";
  return join(homedir(), ".loomkin", "memory", "agents", safe);
}

function ensureDir(dir: string): void {
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}

function safeName(raw: string): string {
  return (
    raw
      .toLowerCase()
      .replace(/[^a-z0-9_-]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 60) || "memory"
  );
}

function parseMemoryFile(
  filePath: string,
  scope: MemoryEntry["scope"],
  agentName?: string,
): MemoryEntry | null {
  try {
    const raw = readFileSync(filePath, "utf-8");
    // Parse YAML frontmatter: --- ... ---
    const frontmatterMatch = raw.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
    if (!frontmatterMatch) return null;

    const [, frontmatter, body] = frontmatterMatch as [string, string, string];

    const nameMatch = frontmatter.match(/^name:\s*(.+)$/m);
    const typeMatch = frontmatter.match(/^type:\s*(.+)$/m);

    const name = nameMatch?.[1]?.trim() ?? "";
    const type = typeMatch?.[1]?.trim() ?? "general";
    const content = body.trim();

    if (!name) return null;

    return { name, type, content, filePath, scope, agentName };
  } catch {
    return null;
  }
}

function loadFromDir(dir: string, scope: MemoryEntry["scope"], agentName?: string): MemoryEntry[] {
  if (!existsSync(dir)) return [];

  try {
    const files = readdirSync(dir).filter((f) => f.endsWith(".md"));
    return files
      .map((f) => parseMemoryFile(join(dir, f), scope, agentName))
      .filter((e): e is MemoryEntry => e !== null);
  } catch {
    return [];
  }
}

/**
 * Load all memory entries from global (~/.loomkin/memory/) and project
 * (<cwd>/.loomkin/memory/) directories. Project entries win on name collision.
 */
export function loadAllMemories(cwd?: string): MemoryEntry[] {
  const globalEntries = loadFromDir(getGlobalMemoryDir(), "global");
  const projectEntries = loadFromDir(getProjectMemoryDir(cwd), "project");

  // Project entries win on name collision
  const byName = new Map<string, MemoryEntry>();
  for (const e of globalEntries) byName.set(e.name, e);
  for (const e of projectEntries) byName.set(e.name, e);

  return Array.from(byName.values());
}

/**
 * Load memory entries scoped to a specific agent.
 */
export function loadAgentMemories(agentName: string): MemoryEntry[] {
  return loadFromDir(getAgentMemoryDir(agentName), "agent", agentName);
}

/** Returns all known agent names (subdirectories of the agents dir). */
export function listAgentNames(): string[] {
  const agentsDir = join(homedir(), ".loomkin", "memory", "agents");
  if (!existsSync(agentsDir)) return [];
  try {
    return readdirSync(agentsDir, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name);
  } catch {
    return [];
  }
}

/**
 * Save a memory entry.
 * @param scope - 'global' saves to ~/.loomkin/memory/
 *                'project' saves to <cwd>/.loomkin/memory/
 *                'agent' saves to ~/.loomkin/memory/agents/<agentName>/
 */
export function saveMemory(
  name: string,
  type: string,
  content: string,
  scope: MemoryEntry["scope"] = "global",
  agentName?: string,
): void {
  let dir: string;
  if (scope === "agent" && agentName) {
    dir = getAgentMemoryDir(agentName);
  } else if (scope === "project") {
    dir = getProjectMemoryDir();
  } else {
    dir = getGlobalMemoryDir();
  }

  ensureDir(dir);
  const safe = safeName(name);
  const filePath = join(dir, `${safe}.md`);
  const frontmatter = `---\nname: ${name}\ntype: ${type}\n---\n${content}\n`;
  writeFileSync(filePath, frontmatter, "utf-8");
}

/**
 * Delete a memory by exact or fuzzy name match.
 * Returns true if deleted, false if not found.
 */
export function deleteMemory(name: string): boolean {
  const memories = loadAllMemories();
  const normalized = name.toLowerCase();

  // Exact match first
  const exact = memories.find((m) => m.name.toLowerCase() === normalized);
  const target = exact ?? memories.find((m) => m.name.toLowerCase().includes(normalized));

  if (!target) return false;

  try {
    unlinkSync(target.filePath);
    return true;
  } catch {
    return false;
  }
}

/**
 * Format memories for injection into the system prompt.
 * Caps output at MAX_PROMPT_CHARS to avoid bloating context.
 */
export function formatMemoriesForPrompt(entries: MemoryEntry[]): string {
  if (entries.length === 0) return "";

  const lines: string[] = ["Persistent memory:"];
  let totalChars = lines[0].length;

  for (const entry of entries) {
    const block = `\n[${entry.name} (${entry.type})]\n${entry.content}`;
    if (totalChars + block.length > MAX_PROMPT_CHARS) {
      lines.push(`\n(${entries.length - lines.length + 1} more memories omitted)`);
      break;
    }
    lines.push(block);
    totalChars += block.length;
  }

  return lines.join("") + "\n";
}
