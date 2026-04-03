import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getSessionChannel } from "./channelUtil.js";
import { usePaneStore } from "../stores/paneStore.js";

register({
  name: "cancel",
  description: "Cancel an agent's in-progress loop",
  args: "[agent-name]",
  handler: async (args: string, ctx: CommandContext) => {
    const channel = getSessionChannel();
    if (!channel) {
      ctx.addSystemMessage(pc.red("No active session."));
      return;
    }

    const agentName = args.trim() || usePaneStore.getState().focusedTarget;
    if (!agentName) {
      ctx.addSystemMessage(pc.red("Usage: /cancel <agent-name>"));
      return;
    }

    channel
      .push("cancel_agent", { agent_name: agentName })
      .receive("ok", () => {
        ctx.addSystemMessage(`${pc.red("✕")} Cancelled ${pc.bold(agentName)}`);
      })
      .receive("error", (raw: Record<string, unknown>) => {
        const reason = typeof raw?.reason === "string" ? raw.reason : "unknown error";
        ctx.addSystemMessage(pc.red(`Failed: ${reason}`));
      });
  },
});
