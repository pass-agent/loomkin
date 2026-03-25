import { register } from "./registry.js";
import { setConfig } from "../lib/config.js";
import { useAppStore } from "../stores/appStore.js";
import { defaultKeymap, vimNormalKeymap, vimInsertKeymap } from "../lib/keymap.js";
import type { KeybindMode, KeyBinding } from "../lib/keymap.js";

const VALID_MODES: KeybindMode[] = ["default", "vim"];

function formatBinding(b: KeyBinding): string {
  const parts: string[] = [];
  if (b.ctrl) parts.push("Ctrl");
  if (b.meta) parts.push("Meta");
  if (b.shift) parts.push("Shift");
  parts.push(b.key);
  return parts.join("+");
}

function formatBindingList(bindings: KeyBinding[], label: string): string {
  const lines = [`  ${label}:`];
  for (const b of bindings) {
    lines.push(`    ${formatBinding(b).padEnd(16)} → ${b.action}`);
  }
  return lines.join("\n");
}

register({
  name: "keybinds",
  aliases: ["kb", "keys"],
  description: "Switch keybinding mode or show current bindings",
  args: "[default|vim|show]",
  handler: (args, ctx) => {
    const arg = args.trim().toLowerCase();
    const store = useAppStore.getState();

    if (!arg || arg === "show") {
      const current = store.keybindMode;
      const lines = [`Keybinding mode: ${current}`];

      if (current === "vim") {
        lines.push("");
        lines.push(formatBindingList(vimNormalKeymap, "Normal mode"));
        lines.push("");
        lines.push(formatBindingList(vimInsertKeymap, "Insert mode"));
        lines.push("");
        lines.push("  Tips:");
        lines.push("    i/a/A/I    Enter insert mode");
        lines.push("    Escape     Return to normal mode");
        lines.push("    :          Open command line (same as /)");
        lines.push("    hjkl       Navigate (h/l cursor, j/k scroll)");
        lines.push("    w/b        Word forward/backward");
        lines.push("    x          Delete character");
        lines.push("    u          Undo");
        lines.push("    Enter      Send message");
      } else {
        lines.push("");
        lines.push(formatBindingList(defaultKeymap, "Default bindings"));
      }

      ctx.addSystemMessage(lines.join("\n"));
      return;
    }

    if (VALID_MODES.includes(arg as KeybindMode)) {
      const mode = arg as KeybindMode;
      store.setKeybindMode(mode);
      setConfig({ keybindMode: mode });
      ctx.addSystemMessage(
        `Keybinding mode set to "${mode}". ${mode === "vim" ? "Press i to enter insert mode, Escape for normal mode." : "Standard keybindings active."}`,
      );
      return;
    }

    ctx.addSystemMessage(
      `Unknown keybinding mode: "${arg}". Available: ${VALID_MODES.join(", ")}`,
    );
  },
});
