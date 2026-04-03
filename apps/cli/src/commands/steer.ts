import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getSessionChannel } from "./channelUtil.js";
import { usePaneStore } from "../stores/paneStore.js";

register({
  name: "steer",
  description: "Inject guidance and resume a paused agent",
  args: "[agent-name] <guidance>",
  handler: async (args: string, ctx: CommandContext) => {
    const channel = getSessionChannel();
    if (!channel) {
      ctx.addSystemMessage(pc.red("No active session."));
      return;
    }

    const parts = args.trim().split(/\s+/);
    const focused = usePaneStore.getState().focusedTarget;
    let agentName: string | null;
    let guidance: string;

    if (parts.length >= 2) {
      agentName = parts[0];
      guidance = parts.slice(1).join(" ");
    } else if (focused && parts[0]) {
      agentName = focused;
      guidance = parts.join(" ");
    } else {
      ctx.addSystemMessage(pc.red("Usage: /steer [agent-name] <guidance text>"));
      return;
    }

    if (!agentName) {
      ctx.addSystemMessage(pc.red("Usage: /steer [agent-name] <guidance text>"));
      return;
    }

    channel
      .push("steer_agent", { agent_name: agentName, guidance })
      .receive("ok", () => {
        ctx.addSystemMessage(
          `${pc.green("▶")} Steered ${pc.bold(agentName)}: ${pc.dim(guidance.slice(0, 60))}${guidance.length > 60 ? "..." : ""}`,
        );
      })
      .receive("error", (raw: Record<string, unknown>) => {
        const reason = typeof raw?.reason === "string" ? raw.reason : "unknown error";
        ctx.addSystemMessage(pc.red(`Failed: ${reason}`));
      });
  },
});
