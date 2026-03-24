import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAgentStore } from "../stores/agentStore.js";
import { joinChannel } from "../lib/socket.js";
import type { Channel } from "phoenix";

const BUILT_IN_ROLES = [
  "researcher",
  "coder",
  "reviewer",
  "tester",
  "lead",
  "concierge",
];

function getSessionChannel(): Channel | null {
  const sessionId = useSessionStore.getState().sessionId;
  if (!sessionId) return null;
  return joinChannel(`session:${sessionId}`);
}

register({
  name: "spawn",
  description: "Spawn an agent into the current session's team",
  args: "<role> [name] [--model <model>]",
  handler: async (args: string, ctx: CommandContext) => {
    const parts = args.trim().split(/\s+/);

    if (parts.length === 0 || !parts[0]) {
      const roles = BUILT_IN_ROLES.map((r) => pc.cyan(r)).join(", ");
      ctx.addSystemMessage(
        `Usage: /spawn <role> [name] [--model <model>]\n` +
          `Built-in roles: ${roles}`,
      );
      return;
    }

    const role = parts[0];
    let name: string | undefined;
    let model: string | undefined;

    // Parse optional flags
    for (let i = 1; i < parts.length; i++) {
      if (parts[i] === "--model" && parts[i + 1]) {
        model = parts[i + 1];
        i++;
      } else if (!name) {
        name = parts[i];
      }
    }

    const channel = getSessionChannel();
    if (!channel) {
      ctx.addSystemMessage(pc.red("No active session. Cannot spawn agent."));
      return;
    }

    ctx.addSystemMessage(
      pc.dim(`Spawning ${role} agent${name ? ` "${name}"` : ""}…`),
    );

    const payload: Record<string, string> = { role };
    if (name) payload.name = name;
    if (model) payload.model = model;

    channel
      .push("spawn_agent", payload)
      .receive(
        "ok",
        (resp: Record<string, unknown>) => {
          const { name, role, team_id } = resp as { name: string; role: string; team_id: string };
          useAgentStore.getState().upsertAgent(name, {
            role,
            teamId: team_id,
            status: "idle",
          });

          ctx.addSystemMessage(
            `${pc.green("✔")} Spawned ${pc.bold(name)} (${pc.cyan(role)}) in team ${pc.dim(team_id.slice(0, 8))}`,
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
