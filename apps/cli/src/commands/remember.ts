import pc from "picocolors";
import { register } from "./registry.js";
import {
  saveMemory,
  loadAllMemories,
  deleteMemory,
} from "../lib/memory.js";

// /remember <text> — save a new memory
register({
  name: "remember",
  description: "Save a persistent memory",
  args: "<text>",
  handler: (args, ctx) => {
    const text = args.trim();
    if (!text) {
      ctx.addSystemMessage(pc.red("Usage: /remember <text>"));
      return;
    }

    // Auto-name from first 30 chars
    const autoName = text.slice(0, 30).replace(/\s+/g, "-").replace(/[^a-z0-9-]/gi, "").toLowerCase();
    const name = autoName || `memory-${Date.now()}`;

    saveMemory(name, "general", text);
    ctx.addSystemMessage(
      pc.green("Memory saved: ") + pc.bold(name),
    );
  },
});

// /memories — list all memories
register({
  name: "memories",
  description: "List all saved memories",
  handler: (_args, ctx) => {
    const entries = loadAllMemories();

    if (entries.length === 0) {
      ctx.addSystemMessage(
        pc.dim("No memories saved. Use /remember <text> to save one."),
      );
      return;
    }

    const lines = [pc.bold(`Memories (${entries.length}):`), ""];
    for (const entry of entries) {
      const preview =
        entry.content.split("\n")[0]?.slice(0, 60) ?? "";
      const ellipsis = entry.content.length > 60 ? "…" : "";
      lines.push(
        `  ${pc.cyan(entry.name)} ${pc.dim(`[${entry.type}]`)}`,
      );
      lines.push(`    ${pc.dim(preview + ellipsis)}`);
    }

    ctx.addSystemMessage(lines.join("\n"));
  },
});

// /forget <name> — delete a memory
register({
  name: "forget",
  description: "Delete a saved memory by name (fuzzy match)",
  args: "<name>",
  handler: (args, ctx) => {
    const name = args.trim();
    if (!name) {
      ctx.addSystemMessage(pc.red("Usage: /forget <name>"));
      return;
    }

    const deleted = deleteMemory(name);
    if (deleted) {
      ctx.addSystemMessage(pc.green(`Memory "${name}" deleted.`));
    } else {
      ctx.addSystemMessage(
        pc.yellow(`No memory matching "${name}" found.`),
      );
    }
  },
});
