import pc from "picocolors";
import { register } from "./registry.js";
import { paneStore } from "../stores/paneStore.js";
import { agentStore } from "../stores/agentStore.js";
import type { CommandContext } from "./registry.js";

register({
  name: "focus",
  aliases: ["f"],
  description: "Sticky-target a specific agent for all messages, or clear the target",
  args: "[@agent-name | clear]",
  handler: (_args: string, ctx: CommandContext) => {
    const target = _args.trim().replace(/^@/, "");

    if (!target || target === "clear") {
      paneStore.getState().setFocusedTarget(null);
      ctx.addSystemMessage(pc.dim("Target cleared. Messages go to the main session."));
      return;
    }

    const agents = agentStore.getState().getAgentList();
    const match = agents.find((a) => a.name === target);

    if (!match) {
      const names = agents.map((a) => pc.cyan(a.name)).join(", ");
      ctx.addSystemMessage(
        pc.yellow(`No agent named "${target}".`) +
          (names ? `\nAvailable: ${names}` : "\nNo agents are currently active."),
      );
      return;
    }

    paneStore.getState().setFocusedTarget(target);
    ctx.addSystemMessage(
      pc.green(`Focused on ${pc.bold(target)}. All messages will target this agent.`) +
        pc.dim(`\nUse /focus clear to broadcast to all agents again.`),
    );
  },
});
