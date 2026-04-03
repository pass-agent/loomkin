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
      ctx.showListPicker?.({
        title: "Select mode",
        items: [
          { value: "code", label: "Code", hint: "write and edit code" },
          { value: "plan", label: "Plan", hint: "plan and design solutions" },
          { value: "chat", label: "Chat", hint: "general conversation" },
        ],
        currentValue: ctx.appStore.mode,
        onSelect: (mode) => {
          ctx.appStore.setMode(mode as Mode);
          ctx.addSystemMessage(`Switched to ${pc.bold(mode)} mode.`);
        },
        onCancel: () => {},
      });
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
