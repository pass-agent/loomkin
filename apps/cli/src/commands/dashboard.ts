import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";

// eslint-disable-next-line no-control-regex
const stripAnsi = (str: string) => str.replace(/\x1B\[[0-9;]*m/g, "");
import { useAgentStore } from "../stores/agentStore.js";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAppStore } from "../stores/appStore.js";
import { formatTokens, formatCost } from "../lib/format.js";
import { getSession } from "../lib/api.js";

function agentDetail(agent: {
  currentTool?: string;
  currentTask?: string;
  currentThought?: string;
  lastThought?: string;
}): string {
  if (agent.currentTool) {
    return `— ${agent.currentTool}`;
  }

  const thought = (agent.currentThought ?? agent.lastThought ?? "").replace(/\s+/g, " ").trim();
  if (thought) {
    return `— thinking: ${thought.slice(0, 40)}${thought.length > 40 ? "…" : ""}`;
  }

  if (agent.currentTask) {
    return `— ${agent.currentTask.slice(0, 40)}${agent.currentTask.length > 40 ? "…" : ""}`;
  }

  return "Idle";
}

async function renderDashboard(ctx: CommandContext) {
  const { sessionId } = useSessionStore.getState();
  const { agents } = useAgentStore.getState();
  const { mode, model, connectionState } = useAppStore.getState();

  const lines: string[] = [
    pc.bold(
      pc.cyan("┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"),
    ),
    pc.bold(pc.cyan("┃")) +
      pc.bold("  LOOMKIN MISSION CONTROL  ") +
      pc.dim("v1.0.0") +
      pc.bold(pc.cyan(" ".repeat(42) + "┃")),
    pc.bold(
      pc.cyan("┠──────────────────────────────────────────────────────────────────────────────┨"),
    ),
  ];

  // Connection & Session Info
  const statusLine = `  ${connectionState === "connected" ? pc.green("●") : pc.red("○")} ${connectionState}  ${pc.dim("│")}  Mode: ${pc.bold(mode)}  ${pc.dim("│")}  Model: ${pc.bold(model)}`;
  lines.push(
    pc.bold(pc.cyan("┃")) +
      statusLine +
      " ".repeat(78 - stripAnsi(statusLine).length) +
      pc.bold(pc.cyan("┃")),
  );

  if (sessionId) {
    try {
      const { session } = await getSession(sessionId);
      const sessionLine = `  Session: ${pc.cyan(sessionId.slice(0, 8))}  ${pc.dim("│")}  Tokens: ${pc.yellow(formatTokens(session.prompt_tokens + session.completion_tokens))}  ${pc.dim("│")}  Cost: ${pc.green(formatCost(session.cost_usd))}`;
      lines.push(
        pc.bold(pc.cyan("┃")) +
          sessionLine +
          " ".repeat(78 - stripAnsi(sessionLine).length) +
          pc.bold(pc.cyan("┃")),
      );
    } catch {
      const sessionLine = `  Session: ${pc.cyan(sessionId.slice(0, 8))} ${pc.dim("(details unavailable)")}`;
      lines.push(
        pc.bold(pc.cyan("┃")) +
          sessionLine +
          " ".repeat(78 - stripAnsi(sessionLine).length) +
          pc.bold(pc.cyan("┃")),
      );
    }
  }

  lines.push(
    pc.bold(
      pc.cyan("┠──────────────────────────────────────────────────────────────────────────────┨"),
    ),
  );
  lines.push(
    pc.bold(pc.cyan("┃")) +
      pc.bold("  ACTIVE AGENTS  ") +
      pc.dim(`(${agents.size})`) +
      " ".repeat(78 - 18 - agents.size.toString().length) +
      pc.bold(pc.cyan("┃")),
  );

  if (agents.size === 0) {
    const noAgentsLine = `  ${pc.dim("No agents active. Spawn agents with /spawn <role>")}`;
    lines.push(
      pc.bold(pc.cyan("┃")) +
        noAgentsLine +
        " ".repeat(78 - stripAnsi(noAgentsLine).length) +
        pc.bold(pc.cyan("┃")),
    );
  } else {
    Array.from(agents.values()).forEach((agent) => {
      const published =
        (agent.publishedFindingsCount ?? 0) > 0
          ? ` ${pc.green(`[pub:${agent.publishedFindingsCount}]`)}`
          : "";
      const agentLine = `  ${agent.status === "working" ? pc.green("●") : pc.dim("○")} ${pc.bold(agent.name)} ${pc.cyan(`[${agent.role}]`)}${published} ${pc.dim(agentDetail(agent))}`;
      lines.push(
        pc.bold(pc.cyan("┃")) +
          agentLine +
          " ".repeat(78 - stripAnsi(agentLine).length) +
          pc.bold(pc.cyan("┃")),
      );
    });
  }

  lines.push(
    pc.bold(
      pc.cyan("┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"),
    ),
  );

  ctx.addSystemMessage(lines.join("\n"));
}

register({
  name: "dashboard",
  aliases: ["db"],
  description: "Show a unified overview of the current session, agents, and system status",
  handler: async (_args: string, ctx: CommandContext) => {
    await renderDashboard(ctx);
  },
});
