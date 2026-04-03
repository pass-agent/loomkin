import { register, type CommandContext } from "./registry.js";

register({
  name: "exit",
  aliases: ["quit", "q"],
  description: "Exit the TUI",
  handler: (_args: string, ctx: CommandContext) => {
    ctx.exit();
  },
});
