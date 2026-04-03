import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getSessionChannel } from "./channelUtil.js";
import { usePaneStore } from "../stores/paneStore.js";

register({
  name: "resume",
  description: "Resume a paused agent with optional guidance",
  args: "[agent-name] [guidance text]",
  handler: async (args: string, ctx: CommandContext) => {
    const channel = getSessionChannel();
    if (!channel) {
      ctx.addSystemMessage(pc.red("No active session."));
      return;
    }

    const parts = args.trim().split(/\s+/);
    const agentName = parts[0] || usePaneStore.getState().focusedTarget;
    const guidance = parts.length > 1 ? parts.slice(1).join(" ") : undefined;

    if (!agentName) {
      ctx.addSystemMessage(pc.red("Usage: /resume <agent-name> [guidance]"));
      return;
    }

    const payload: Record<string, string> = { agent_name: agentName };
    if (guidance) payload.guidance = guidance;

    channel
      .push("resume_agent", payload)
      .receive("ok", () => {
        const msg = guidance
          ? `${pc.green("▶")} Resumed ${pc.bold(agentName)} with guidance`
          : `${pc.green("▶")} Resumed ${pc.bold(agentName)}`;
        ctx.addSystemMessage(msg);
      })
      .receive("error", (raw: Record<string, unknown>) => {
        const reason = typeof raw?.reason === "string" ? raw.reason : "unknown error";
        ctx.addSystemMessage(pc.red(`Failed: ${reason}`));
      });
  },
});
