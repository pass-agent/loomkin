export interface KeyBinding {
  key: string;
  ctrl?: boolean;
  shift?: boolean;
  meta?: boolean;
  action: string;
}

export type KeybindMode = "default" | "vim";
export type VimMode = "normal" | "insert" | "command";

export const defaultKeymap: KeyBinding[] = [
  { key: "c", ctrl: true, action: "quit" },
  { key: "d", ctrl: true, action: "quit" },
  { key: "l", ctrl: true, action: "clear" },
  { key: "k", ctrl: true, action: "scrollUp" },
  { key: "j", ctrl: true, action: "scrollDown" },
  { key: "t", ctrl: true, action: "toggleSplit" },
  { key: "v", ctrl: true, action: "toggleVerboseToolOutput" },
  { key: "tab", action: "switchFocus" },
  { key: "]", action: "nextAgent" },
  { key: "[", action: "prevAgent" },
];

/**
 * Vim normal mode bindings.
 * These only apply when keybindMode is "vim" and vimMode is "normal".
 */
export const vimNormalKeymap: KeyBinding[] = [
  // Mode transitions
  { key: "i", action: "vim:insert" },
  { key: "a", action: "vim:append" },
  { key: "A", shift: true, action: "vim:appendEnd" },
  { key: "I", shift: true, action: "vim:insertStart" },
  { key: "o", action: "vim:openBelow" },

  // Navigation
  { key: "h", action: "vim:left" },
  { key: "l", action: "vim:right" },
  { key: "j", action: "scrollDown" },
  { key: "k", action: "scrollUp" },
  { key: "w", action: "vim:wordForward" },
  { key: "b", action: "vim:wordBackward" },
  { key: "0", action: "vim:lineStart" },
  { key: "$", action: "vim:lineEnd" },

  // Editing
  { key: "x", action: "vim:deleteChar" },
  { key: "d", action: "vim:deletePending" },
  { key: "c", action: "vim:changePending" },
  { key: "u", action: "vim:undo" },

  // Clipboard
  { key: "y", action: "vim:yankPending" },
  { key: "p", action: "vim:paste" },

  // History
  { key: "/", action: "vim:searchHistory" },
  { key: ":", action: "vim:command" },

  // Submit (Enter in normal mode sends the current buffer)
  { key: "return", action: "submit" },

  // Global bindings still active in normal mode
  { key: "c", ctrl: true, action: "quit" },
  { key: "d", ctrl: true, action: "quit" },
  { key: "t", ctrl: true, action: "toggleSplit" },
  { key: "v", ctrl: true, action: "toggleVerboseToolOutput" },
];

/**
 * Vim insert mode bindings.
 * Only escape/ctrl bindings — all other input goes to the text buffer.
 */
export const vimInsertKeymap: KeyBinding[] = [
  { key: "escape", action: "vim:normal" },
  { key: "[", ctrl: true, action: "vim:normal" }, // ctrl+[ = escape
  { key: "c", ctrl: true, action: "quit" },
  { key: "d", ctrl: true, action: "quit" },
  { key: "t", ctrl: true, action: "toggleSplit" },
  { key: "v", ctrl: true, action: "toggleVerboseToolOutput" },
];

export function matchKey(
  input: { key: string; ctrl?: boolean; shift?: boolean; meta?: boolean },
  binding: KeyBinding,
): boolean {
  return (
    input.key === binding.key &&
    !!input.ctrl === !!binding.ctrl &&
    !!input.shift === !!binding.shift &&
    !!input.meta === !!binding.meta
  );
}

/**
 * Find the first matching action for a key input in the given keymap.
 */
export function findAction(
  input: { key: string; ctrl?: boolean; shift?: boolean; meta?: boolean },
  keymap: KeyBinding[],
): string | null {
  for (const binding of keymap) {
    if (matchKey(input, binding)) return binding.action;
  }
  return null;
}

/**
 * Get the appropriate keymap for the current vim mode.
 */
export function getVimKeymap(vimMode: VimMode): KeyBinding[] {
  switch (vimMode) {
    case "normal":
      return vimNormalKeymap;
    case "insert":
      return vimInsertKeymap;
    case "command":
      return vimInsertKeymap; // command mode uses same escape bindings
  }
}
