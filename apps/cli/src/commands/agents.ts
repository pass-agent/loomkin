import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { useAgentStore, type AgentInfo } from "../stores/agentStore.js";

const STATUS_ICONS: Record<string, string> = {
  working: pc.green("●"),
  idle: pc.dim("○"),
  blocked: pc.yellow("◉"),
  paused: pc.blue("◎"),
  error: pc.red("✖"),
  waiting_permission: pc.yellow("⏳"),
  approval_pending: pc.yellow("⏳"),
  ask_user_pending: pc.cyan("?"),
  complete: pc.green("✔"),
  crashed: pc.red("💀"),
  recovering: pc.yellow("↻"),
  permanently_failed: pc.red("✖✖"),
};

function formatAgent(agent: AgentInfo): string {
  const icon = STATUS_ICONS[agent.status] || pc.dim("○");
  const name = pc.bold(agent.name);
  const role = pc.cyan(agent.role);
  const status = agent.status;

  let detail = "";
  if (agent.currentTool) {
    detail = pc.dim(` → ${agent.currentTool}`);
  } else if (agent.currentTask) {
    const taskPreview =
      agent.currentTask.length > 50
        ? agent.currentTask.slice(0, 50) + "…"
        : agent.currentTask;
    detail = pc.dim(` — ${taskPreview}`);
  } else if (agent.lastError && agent.status === "error") {
    detail = pc.red(` — ${agent.lastError.slice(0, 60)}`);
  }

  let cost = "";
  if (agent.costUsd != null) {
    cost = pc.dim(` $${agent.costUsd.toFixed(4)}`);
  }

  let worktree = "";
  if (agent.worktreePath) {
    worktree = pc.dim(` [wt:${agent.worktreePath}]`);
  }

  return `  ${icon} ${name} ${role} ${pc.dim(`[${status}]`)}${detail}${cost}${worktree}`;
}

register({
  name: "agents",
  aliases: ["a"],
  description: "List active agents and their status",
  handler: (_args: string, ctx: CommandContext) => {
    const agents = useAgentStore.getState().getAgentList();

    if (agents.length === 0) {
      ctx.addSystemMessage(
        pc.dim("No agents active. Agents appear when the session spawns a team."),
      );
      return;
    }

    const header = pc.bold(`Active agents (${agents.length})`);
    const lines = agents.map(formatAgent);

    ctx.addSystemMessage(`${header}\n${lines.join("\n")}`);
  },
});
