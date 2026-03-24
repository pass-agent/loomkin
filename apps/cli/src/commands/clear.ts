import { register, type CommandContext } from "./registry.js";

register({
  name: "clear",
  aliases: ["cls"],
  description: "Clear the message history",
  handler: (_args: string, ctx: CommandContext) => {
    ctx.clearMessages();
    ctx.addSystemMessage("Messages cleared.");
  },
});
