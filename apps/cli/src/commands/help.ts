import pc from "picocolors";
import { register, getAllCommands, type CommandContext } from "./registry.js";

register({
  name: "help",
  aliases: ["h", "?"],
  description: "List all available commands",
  handler: (_args: string, ctx: CommandContext) => {
    const commands = getAllCommands();
    const lines = [
      pc.bold("Available commands:"),
      "",
      ...commands.map((cmd) => {
        const aliases = cmd.aliases?.length
          ? pc.dim(` (${cmd.aliases.map((a) => `/${a}`).join(", ")})`)
          : "";
        const args = cmd.args ? pc.cyan(` ${cmd.args}`) : "";
        return `  ${pc.green(`/${cmd.name}`)}${args}${aliases}  ${pc.dim(cmd.description)}`;
      }),
      "",
      pc.dim("Type / to see autocomplete suggestions."),
    ];
    ctx.addSystemMessage(lines.join("\n"));
  },
});
