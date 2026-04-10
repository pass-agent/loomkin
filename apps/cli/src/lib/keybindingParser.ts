import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import type { KeyBinding } from "./keymap.js";
import { logger } from "./logger.js";

export interface KeybindingOverride {
  [action: string]: string; // e.g. "submit": "ctrl+enter"
}

// Actions that must never be rebound for safety
const PROTECTED_ACTIONS = new Set(["quit"]);
// Keys that must never be rebound (ctrl+c / ctrl+d)
const PROTECTED_KEYS = new Set(["ctrl+c", "ctrl+d"]);

function getKeybindingsPath(): string {
  return join(homedir(), ".loomkin", "keybindings.json");
}

/**
 * Parse a key combo string like "ctrl+enter", "shift+tab", "ctrl+l"
 * into a partial KeyBinding.
 */
function parseKeyCombo(combo: string): Partial<KeyBinding> | null {
  const parts = combo.toLowerCase().split("+");
  const key = parts[parts.length - 1];
  if (!key) return null;

  const ctrl = parts.includes("ctrl");
  const shift = parts.includes("shift");
  const meta = parts.includes("meta") || parts.includes("alt");

  return {
    key,
    ...(ctrl ? { ctrl: true } : {}),
    ...(shift ? { shift: true } : {}),
    ...(meta ? { meta: true } : {}),
  };
}

/**
 * Load keybindings from ~/.loomkin/keybindings.json.
 * Returns an empty object if the file does not exist or is malformed.
 */
export function loadKeybindings(): KeybindingOverride {
  const path = getKeybindingsPath();
  if (!existsSync(path)) return {};

  try {
    const content = readFileSync(path, "utf-8");
    const parsed = JSON.parse(content);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return {};
    }

    const result: KeybindingOverride = {};
    for (const [action, combo] of Object.entries(parsed)) {
      if (typeof combo !== "string") continue;
      const normalizedCombo = (combo as string).toLowerCase();

      // Refuse to rebind protected keys
      if (PROTECTED_KEYS.has(normalizedCombo)) {
        logger.debug(
          `[keybindings] cannot rebind protected key "${combo}" for action "${action}" — skipped`,
        );
        continue;
      }
      // Refuse to rebind protected actions
      if (PROTECTED_ACTIONS.has(action.toLowerCase())) {
        logger.debug(`[keybindings] cannot rebind protected action "${action}" — skipped`);
        continue;
      }

      result[action] = normalizedCombo;
    }
    return result;
  } catch {
    return {};
  }
}

/**
 * Merge user keybinding overrides onto a default keymap.
 * Overrides replace bindings matching the same action; other defaults remain.
 */
export function mergeKeybindings(
  defaults: KeyBinding[],
  overrides: KeybindingOverride,
): KeyBinding[] {
  if (Object.keys(overrides).length === 0) return defaults;

  // Build override map: action -> parsed key combo
  const overrideMap = new Map<string, Partial<KeyBinding>>();
  for (const [action, combo] of Object.entries(overrides)) {
    const parsed = parseKeyCombo(combo);
    if (parsed) overrideMap.set(action, parsed);
  }

  return defaults.map((binding) => {
    const override = overrideMap.get(binding.action);
    if (!override) return binding;
    return { ...binding, ...override };
  });
}
