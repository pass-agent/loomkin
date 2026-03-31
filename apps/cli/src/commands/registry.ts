import type { AppState } from "../stores/appStore.js";
import type { SessionState } from "../stores/sessionStore.js";
import type { ModelProvider } from "../lib/types.js";

export interface ListPickerItem {
  value: string;
  label: string;
  hint?: string;
}

export interface ListPickerOptions {
  title: string;
  items: ListPickerItem[];
  currentValue?: string;
  onSelect: (value: string, label: string) => void;
  onCancel: () => void;
}

export interface CommandContext {
  appStore: AppState;
  sessionStore: SessionState;
  addSystemMessage: (content: string) => void;
  sendMessage: (content: string) => void;
  clearMessages: () => void;
  exit: () => void;
  showModelPicker?: (providers: ModelProvider[]) => void;
  setSessionModel?: (model: string) => void;
  captureNextInput?: (callback: (input: string) => void) => void;
  showListPicker?: (options: ListPickerOptions) => void;
}

export interface SlashCommand {
  name: string;
  aliases?: string[];
  description: string;
  args?: string;
  handler: (args: string, ctx: CommandContext) => Promise<void> | void;
}

const commands = new Map<string, SlashCommand>();
const aliasMap = new Map<string, string>();

// Track which commands are built-in (registered before plugins load)
export const BUILTIN_COMMANDS = new Set<string>();

export function register(cmd: SlashCommand): void {
  commands.set(cmd.name, cmd);
  if (cmd.aliases) {
    for (const alias of cmd.aliases) {
      aliasMap.set(alias, cmd.name);
    }
  }
}

/** Register a built-in command and mark it as protected. */
export function registerBuiltin(cmd: SlashCommand): void {
  register(cmd);
  BUILTIN_COMMANDS.add(cmd.name);
}

/**
 * Mark all currently registered commands as built-in.
 * Call this after all built-in command files have been imported
 * and before any plugins are loaded.
 */
export function markCurrentAsBuiltins(): void {
  for (const name of commands.keys()) {
    BUILTIN_COMMANDS.add(name);
  }
}

export function resolve(
  input: string,
): { command: SlashCommand; args: string } | null {
  const trimmed = input.trim();
  if (!trimmed.startsWith("/")) return null;

  const [rawName, ...rest] = trimmed.slice(1).split(/\s+/);
  const name = rawName.toLowerCase();
  const args = rest.join(" ");

  const resolved = commands.get(name) ?? commands.get(aliasMap.get(name) ?? "");
  if (!resolved) return null;

  return { command: resolved, args };
}

export function getCompletions(partial: string): SlashCommand[] {
  const query = partial.toLowerCase().replace(/^\//, "");
  const results: SlashCommand[] = [];

  for (const cmd of commands.values()) {
    if (cmd.name.startsWith(query)) {
      results.push(cmd);
      continue;
    }
    if (cmd.aliases?.some((a) => a.startsWith(query))) {
      results.push(cmd);
    }
  }

  return results.sort((a, b) => a.name.localeCompare(b.name));
}

export function getAllCommands(): SlashCommand[] {
  return Array.from(commands.values()).sort((a, b) =>
    a.name.localeCompare(b.name),
  );
}
