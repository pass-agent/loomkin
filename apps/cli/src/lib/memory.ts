import { readFileSync, writeFileSync, readdirSync, unlinkSync, mkdirSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

export interface MemoryEntry {
  name: string;
  type: string;
  content: string;
  filePath: string;
}

const MAX_PROMPT_CHARS = 2000;

export function getMemoryDir(): string {
  return join(homedir(), ".loomkin", "memory");
}

function ensureMemoryDir(): void {
  const dir = getMemoryDir();
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}

function safeName(raw: string): string {
  // Sanitize to valid filename chars
  return raw
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60) || "memory";
}

function parseMemoryFile(filePath: string): MemoryEntry | null {
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

    return { name, type, content, filePath };
  } catch {
    return null;
  }
}

/**
 * Load all memory entries from ~/.loomkin/memory/*.md
 */
export function loadAllMemories(): MemoryEntry[] {
  const dir = getMemoryDir();
  if (!existsSync(dir)) return [];

  try {
    const files = readdirSync(dir).filter((f) => f.endsWith(".md"));
    return files
      .map((f) => parseMemoryFile(join(dir, f)))
      .filter((e): e is MemoryEntry => e !== null);
  } catch {
    return [];
  }
}

/**
 * Save a memory entry to ~/.loomkin/memory/<name>.md
 */
export function saveMemory(name: string, type: string, content: string): void {
  ensureMemoryDir();
  const safe = safeName(name);
  const filePath = join(getMemoryDir(), `${safe}.md`);
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
