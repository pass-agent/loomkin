import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getSessionChannel } from "./channelUtil.js";
import { usePaneStore } from "../stores/paneStore.js";

register({
  name: "pause",
  description: "Pause an agent at its next checkpoint",
  args: "[agent-name]",
  handler: async (args: string, ctx: CommandContext) => {
    const channel = getSessionChannel();
    if (!channel) {
      ctx.addSystemMessage(pc.red("No active session."));
      return;
    }

    const agentName = args.trim() || usePaneStore.getState().focusedTarget;
    if (!agentName) {
      ctx.addSystemMessage(pc.red("Usage: /pause <agent-name>"));
      return;
    }

    channel
      .push("pause_agent", { agent_name: agentName })
      .receive("ok", () => {
        ctx.addSystemMessage(`${pc.yellow("⏸")} Pause requested for ${pc.bold(agentName)}`);
      })
      .receive("error", (raw: Record<string, unknown>) => {
        const reason = typeof raw?.reason === "string" ? raw.reason : "unknown error";
        ctx.addSystemMessage(pc.red(`Failed: ${reason}`));
      });
  },
});
