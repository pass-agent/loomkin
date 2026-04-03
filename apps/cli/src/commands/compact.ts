import { register, type CommandContext } from "./registry.js";
import { useChannelStore } from "../stores/channelStore.js";

register({
  name: "compact",
  description: "Summarize and compact conversation history",
  handler: (_args: string, ctx: CommandContext) => {
    const channel = useChannelStore.getState().getChannel();
    if (!channel) {
      ctx.addSystemMessage("Not connected to session. Cannot compact.");
      return;
    }

    channel.push("compact_history", {})
      .receive("ok", () => {
        ctx.addSystemMessage("Compaction requested. Waiting for server...");
      })
      .receive("error", (resp: Record<string, unknown>) => {
        ctx.addSystemMessage(
          `Compaction failed: ${typeof resp.reason === "string" ? resp.reason : "unknown error"}`,
        );
      });
  },
});
