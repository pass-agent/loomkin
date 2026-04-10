import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getDecisions, ApiError } from "../lib/api.js";
import type { DecisionNode } from "../lib/types.js";

function nodeIcon(type: string): string {
  switch (type) {
    case "goal":
      return "🎯";
    case "decision":
      return "⚖️";
    case "action":
      return "⚡";
    case "outcome":
      return "✅";
    case "observation":
      return "👁";
    case "option":
      return "💡";
    case "revisit":
      return "🔄";
    default:
      return "•";
  }
}

function statusColor(status: string): (s: string) => string {
  switch (status) {
    case "active":
      return pc.green;
    case "completed":
    case "resolved":
      return pc.dim;
    case "blocked":
      return pc.red;
    case "deferred":
      return pc.yellow;
    default:
      return (s: string) => s;
  }
}

function formatNode(node: DecisionNode): string {
  const icon = nodeIcon(node.node_type);
  const color = statusColor(node.status);
  const conf = node.confidence !== null ? pc.dim(` ${node.confidence}%`) : "";
  const agent = node.agent_name ? pc.cyan(` @${node.agent_name}`) : "";
  const id = pc.dim(node.id.slice(0, 8));
  const date = new Date(node.inserted_at).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

  const line1 = `  ${icon} ${color(node.title)}${conf}${agent}`;
  const line2 = `    ${id}  ${pc.dim(node.status)}  ${pc.dim(date)}`;

  if (node.description) {
    const desc =
      node.description.length > 100 ? node.description.slice(0, 100) + "…" : node.description;
    return `${line1}\n    ${pc.dim(desc)}\n${line2}`;
  }

  return `${line1}\n${line2}`;
}

register({
  name: "logs",
  aliases: ["log", "decisions"],
  description: "View the decision log (goals, decisions, actions, outcomes)",
  args: "[goals|recent|pulse|search <query>]",
  handler: async (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0]?.toLowerCase() ?? "";

    try {
      switch (subcommand) {
        case "goals":
        case "active": {
          const { nodes } = await getDecisions({ type: "active_goals" });
          if (!nodes || nodes.length === 0) {
            ctx.addSystemMessage(pc.dim("No active goals."));
            return;
          }
          const lines = [pc.bold("Active Goals"), "", ...nodes.map(formatNode)];
          ctx.addSystemMessage(lines.join("\n"));
          break;
        }

        case "pulse":
        case "health": {
          const result = await getDecisions({ type: "pulse" });
          const score = result.health_score ?? 0;
          const color = score >= 70 ? pc.green : score >= 40 ? pc.yellow : pc.red;
          ctx.addSystemMessage(
            `${pc.bold("Pulse")} ${color(`${score}/100`)}\n${result.summary ?? "No summary available."}`,
          );
          break;
        }

        case "search":
        case "find": {
          const query = parts.slice(1).join(" ");
          if (!query) {
            ctx.addSystemMessage(`Usage: ${pc.cyan("/logs search <query>")}`);
            return;
          }
          const { nodes } = await getDecisions({
            type: "search",
            q: query,
          });
          if (!nodes || nodes.length === 0) {
            ctx.addSystemMessage(pc.dim(`No decisions matching "${query}".`));
            return;
          }
          const lines = [pc.bold(`Decisions matching "${query}"`), "", ...nodes.map(formatNode)];
          ctx.addSystemMessage(lines.join("\n"));
          break;
        }

        default: {
          // /logs or /logs recent — show recent decisions
          const limit = subcommand ? parseInt(subcommand, 10) || 20 : 20;
          const { nodes } = await getDecisions({
            type: "recent_decisions",
            limit,
          });
          if (!nodes || nodes.length === 0) {
            ctx.addSystemMessage(pc.dim("No decisions logged yet."));
            return;
          }
          const lines = [
            pc.bold("Recent Decisions"),
            "",
            ...nodes.map(formatNode),
            "",
            pc.dim("/logs goals, /logs pulse, /logs search <query>"),
          ];
          ctx.addSystemMessage(lines.join("\n"));
          break;
        }
      }
    } catch (err) {
      const msg =
        err instanceof ApiError
          ? `Failed to fetch decisions: ${err.body}`
          : "Failed to fetch decisions.";
      ctx.addSystemMessage(pc.red(msg));
    }
  },
});
