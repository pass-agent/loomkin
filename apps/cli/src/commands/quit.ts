import { register, type CommandContext } from "./registry.js";

register({
  name: "quit",
  aliases: ["q", "exit"],
  description: "Exit the TUI",
  handler: (_args: string, ctx: CommandContext) => {
    ctx.exit();
  },
});
