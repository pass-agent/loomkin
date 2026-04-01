import pc from "picocolors";
import { register } from "./registry.js";
import {
  saveMemory,
  loadAllMemories,
  deleteMemory,
  type MemoryEntry,
} from "../lib/memory.js";

// /remember [--scope global|project|agent:<name>] <text>
register({
  name: "remember",
  description: "Save a persistent memory",
  args: "[--scope global|project|agent:<name>] <text>",
  handler: (args, ctx) => {
    const parts = args.trim().split(/\s+/);

    let scope: MemoryEntry["scope"] = "global";
    let agentName: string | undefined;
    let textParts: string[] = [];

    for (let i = 0; i < parts.length; i++) {
      if (parts[i] === "--scope" && parts[i + 1]) {
        const scopeArg = parts[i + 1];
        if (scopeArg.startsWith("agent:")) {
          scope = "agent";
          agentName = scopeArg.slice(6);
        } else if (scopeArg === "project") {
          scope = "project";
        } else {
          scope = "global";
        }
        i++; // skip scope value
      } else {
        textParts.push(parts[i]);
      }
    }

    const text = textParts.join(" ").trim();
    if (!text) {
      ctx.addSystemMessage(
        pc.red("Usage: /remember [--scope global|project|agent:<name>] <text>"),
      );
      return;
    }

    // Auto-name from first 30 chars
    const autoName = text
      .slice(0, 30)
      .replace(/\s+/g, "-")
      .replace(/[^a-z0-9-]/gi, "")
      .toLowerCase();
    const name = autoName || `memory-${Date.now()}`;

    saveMemory(name, "general", text, scope, agentName);
    const scopeLabel =
      scope === "agent" && agentName
        ? `agent:${agentName}`
        : scope;
    ctx.addSystemMessage(
      pc.green("Memory saved: ") + pc.bold(name) + pc.dim(` [${scopeLabel}]`),
    );
  },
});

// /memories — list all memories grouped by scope
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

    const byScope: Record<string, MemoryEntry[]> = {
      global: [],
      project: [],
      agent: [],
    };

    for (const entry of entries) {
      (byScope[entry.scope] ?? byScope["global"]).push(entry);
    }

    const lines: string[] = [pc.bold(`Memories (${entries.length}):`)];

    if (byScope.global.length > 0) {
      lines.push("", pc.bold("## Global"));
      for (const entry of byScope.global) {
        const preview = entry.content.split("\n")[0]?.slice(0, 60) ?? "";
        const ellipsis = entry.content.length > 60 ? "…" : "";
        lines.push(`  ${pc.cyan(entry.name)} ${pc.dim(`[${entry.type}]`)}`);
        lines.push(`    ${pc.dim(preview + ellipsis)}`);
      }
    }

    if (byScope.project.length > 0) {
      lines.push("", pc.bold("## Project"));
      for (const entry of byScope.project) {
        const preview = entry.content.split("\n")[0]?.slice(0, 60) ?? "";
        const ellipsis = entry.content.length > 60 ? "…" : "";
        lines.push(`  ${pc.cyan(entry.name)} ${pc.dim(`[${entry.type}]`)}`);
        lines.push(`    ${pc.dim(preview + ellipsis)}`);
      }
    }

    // Load agent-scoped memories (from agents dirs)
    // These are loaded separately since loadAllMemories() only returns global+project
    const agentEntries = byScope.agent;
    if (agentEntries.length > 0) {
      const byAgent: Record<string, MemoryEntry[]> = {};
      for (const e of agentEntries) {
        const key = e.agentName ?? "unknown";
        if (!byAgent[key]) byAgent[key] = [];
        byAgent[key].push(e);
      }
      for (const [agent, items] of Object.entries(byAgent)) {
        lines.push("", pc.bold(`## Agent: ${agent}`));
        for (const entry of items) {
          const preview = entry.content.split("\n")[0]?.slice(0, 60) ?? "";
          const ellipsis = entry.content.length > 60 ? "…" : "";
          lines.push(`  ${pc.cyan(entry.name)} ${pc.dim(`[${entry.type}]`)}`);
          lines.push(`    ${pc.dim(preview + ellipsis)}`);
        }
      }
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
      ctx.addSystemMessage(pc.yellow(`No memory matching "${name}" found.`));
    }
  },
});
