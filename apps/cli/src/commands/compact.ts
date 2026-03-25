import { register, type CommandContext } from "./registry.js";

register({
  name: "compact",
  description: "Summarize and compact conversation history",
  handler: (_args: string, ctx: CommandContext) => {
    // TODO: send compact request to server via session channel
    ctx.addSystemMessage(
      "Compact requested. The server will summarize the conversation.",
    );
  },
});
