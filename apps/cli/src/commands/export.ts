import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { extractErrorMessage } from "../lib/errors.js";
import { getSession, getSessionMessages } from "../lib/api.js";
import type { Message, Session } from "../lib/types.js";

function toMarkdown(session: Session, messages: Message[]): string {
  const lines: string[] = [];
  const title = session.title || "Untitled session";
  const date = new Date(session.inserted_at).toLocaleString();

  lines.push(`# ${title}`);
  lines.push("");
  lines.push(`- **Session:** ${session.id}`);
  lines.push(`- **Model:** ${session.model}`);
  lines.push(`- **Date:** ${date}`);
  lines.push(`- **Tokens:** ${session.prompt_tokens + session.completion_tokens}`);
  if (session.cost_usd) lines.push(`- **Cost:** $${session.cost_usd}`);
  lines.push("");
  lines.push("---");
  lines.push("");

  for (const msg of messages) {
    if (msg.role === "system") continue;

    const label = formatRole(msg);
    lines.push(`### ${label}`);
    lines.push("");

    if (msg.content) {
      lines.push(msg.content);
      lines.push("");
    }

    if (msg.tool_calls?.length) {
      for (const tc of msg.tool_calls) {
        lines.push(`> **Tool call:** \`${tc.name}\``);
        if (tc.output) {
          lines.push(
            `> **Result:** ${tc.output.slice(0, 200)}${tc.output.length > 200 ? "..." : ""}`,
          );
        }
        lines.push("");
      }
    }
  }

  return lines.join("\n");
}

function toJson(session: Session, messages: Message[]): string {
  return JSON.stringify(
    {
      session: {
        id: session.id,
        title: session.title,
        model: session.model,
        tokens: session.prompt_tokens + session.completion_tokens,
        cost_usd: session.cost_usd,
        created_at: session.inserted_at,
      },
      messages: messages
        .filter((m) => m.role !== "system")
        .map((m) => ({
          role: m.role,
          agent_name: m.agent_name,
          content: m.content,
          tool_calls: m.tool_calls,
          timestamp: m.inserted_at,
        })),
    },
    null,
    2,
  );
}

function formatRole(msg: Message): string {
  if (msg.role === "user") return "User";
  if (msg.role === "assistant") {
    return msg.agent_name ? `Agent (${msg.agent_name})` : "Assistant";
  }
  if (msg.role === "tool") return "Tool";
  return msg.role;
}

register({
  name: "export",
  description: "Export conversation to markdown or JSON file",
  args: "[--json] [--file <path>]",
  handler: async (args: string, ctx: CommandContext) => {
    const sessionId = ctx.sessionStore.sessionId;
    if (!sessionId) {
      ctx.addSystemMessage(pc.red("No active session."));
      return;
    }

    const parts = args.trim().split(/\s+/);
    let format: "md" | "json" = "md";
    let filePath: string | undefined;

    for (let i = 0; i < parts.length; i++) {
      if (parts[i] === "--json") {
        format = "json";
      } else if (parts[i] === "--file" && parts[i + 1]) {
        filePath = parts[i + 1];
        i++;
      } else if (parts[i] === "--md") {
        format = "md";
      }
    }

    try {
      const [{ session }, { messages }] = await Promise.all([
        getSession(sessionId),
        getSessionMessages(sessionId),
      ]);

      if (messages.length === 0) {
        ctx.addSystemMessage(pc.dim("No messages to export."));
        return;
      }

      const content = format === "json" ? toJson(session, messages) : toMarkdown(session, messages);

      const defaultName = `loomkin-${sessionId.slice(0, 8)}.${format === "json" ? "json" : "md"}`;
      const outPath = resolve(filePath || defaultName);

      writeFileSync(outPath, content, "utf-8");

      ctx.addSystemMessage(
        `${pc.green("✔")} Exported ${messages.length} messages → ${pc.bold(outPath)}`,
      );
    } catch (error) {
      const msg = extractErrorMessage(error);
      ctx.addSystemMessage(pc.red(`Export failed: ${msg}`));
    }
  },
});
