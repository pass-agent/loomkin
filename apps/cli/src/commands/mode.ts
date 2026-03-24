import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { MODES, type Mode } from "../lib/constants.js";

register({
  name: "mode",
  aliases: ["m"],
  description: "Switch interaction mode",
  args: "<code|plan|chat>",
  handler: (args: string, ctx: CommandContext) => {
    const requested = args.trim().toLowerCase();

    if (!requested) {
      ctx.addSystemMessage(
        `Current mode: ${pc.bold(ctx.appStore.mode)}\nAvailable: ${MODES.join(", ")}`,
      );
      return;
    }

    if (!MODES.includes(requested as Mode)) {
      ctx.addSystemMessage(
        `Unknown mode "${requested}". Available: ${MODES.join(", ")}`,
      );
      return;
    }

    ctx.appStore.setMode(requested as Mode);
    ctx.addSystemMessage(`Switched to ${pc.bold(requested)} mode.`);
  },
});
