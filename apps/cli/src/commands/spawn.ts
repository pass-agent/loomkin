import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { useAgentStore } from "../stores/agentStore.js";
import { getSessionChannel } from "./channelUtil.js";
import { loadAgentMemories, formatMemoriesForPrompt } from "../lib/memory.js";

const BUILT_IN_ROLES = [
  "researcher",
  "coder",
  "reviewer",
  "tester",
  "lead",
  "concierge",
];

register({
  name: "spawn",
  description: "Spawn an agent into the current session's team",
  args: "<role> [name] [--model <model>] [--worktree]",
  handler: async (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/);

    if (parts.length === 0 || !parts[0]) {
      const roles = BUILT_IN_ROLES.map((r) => pc.cyan(r)).join(", ");
      ctx.addSystemMessage(
        `Usage: /spawn <role> [name] [--model <model>] [--worktree]\n` +
          `Built-in roles: ${roles}`,
      );
      return;
    }

    const role = parts[0];
    let name: string | undefined;
    let model: string | undefined;
    let worktree = false;

    // Parse optional flags
    for (let i = 1; i < parts.length; i++) {
      if (parts[i] === "--model" && parts[i + 1]) {
        model = parts[i + 1];
        i++;
      } else if (parts[i] === "--worktree") {
        worktree = true;
      } else if (!name && !parts[i].startsWith("--")) {
        name = parts[i];
      }
    }

    const channel = getSessionChannel();
    if (!channel) {
      ctx.addSystemMessage(pc.red("No active session. Cannot spawn agent."));
      return;
    }

    ctx.addSystemMessage(
      pc.dim(`Spawning ${role} agent${name ? ` "${name}"` : ""}${worktree ? " (with worktree)" : ""}…`),
    );

    // Load agent-scoped memories to include as additional system prompt
    const agentMemories = [
      ...loadAgentMemories(role),
      ...(name ? loadAgentMemories(name) : []),
    ];
    const agentMemoryPrompt = agentMemories.length > 0
      ? formatMemoriesForPrompt(agentMemories)
      : null;

    const payload: Record<string, unknown> = { role };
    if (name) payload.name = name;
    // Use explicit model, or 'inherit' to inherit from the parent session
    payload.model = model ?? "inherit";
    if (worktree) payload.worktree = true;
    if (agentMemoryPrompt) payload.additional_system_prompt = agentMemoryPrompt;

    channel
      .push("spawn_agent", payload)
      .receive(
        "ok",
        (resp: Record<string, unknown>) => {
          const { name: agentName, role: agentRole, team_id, worktree_path } = resp as {
            name: string;
            role: string;
            team_id: string;
            worktree_path?: string;
          };
          useAgentStore.getState().upsertAgent(agentName, {
            role: agentRole,
            teamId: team_id,
            status: "idle",
            ...(worktree_path ? { worktreePath: worktree_path } : {}),
          });

          const worktreeInfo = worktree_path ? pc.dim(` [worktree: ${worktree_path}]`) : "";
          ctx.addSystemMessage(
            `${pc.green("✔")} Spawned ${pc.bold(agentName)} (${pc.cyan(agentRole)}) in team ${pc.dim(team_id.slice(0, 8))}${worktreeInfo}`,
          );
        },
      )
      .receive("error", (resp: Record<string, unknown>) => {
        const { reason } = resp as { reason: string };
        ctx.addSystemMessage(
          pc.red(`Failed to spawn agent: ${reason}`),
        );
      });
  },
});
