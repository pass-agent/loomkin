import pc from "picocolors";
import { register } from "./registry.js";
import { useAppStore } from "../stores/appStore.js";
import { getSessionChannel } from "./channelUtil.js";

const DEFAULT_BUDGET = 10_000;

register({
  name: "think",
  description: "Toggle extended thinking mode",
  args: "[budget|off]",
  handler: (args, ctx) => {
    const arg = args.trim().toLowerCase();

    if (arg === "off") {
      useAppStore.getState().setThinkingBudget(null);
      const channel = getSessionChannel();
      if (channel) {
        channel
          .push("set_thinking_budget", { budget: null })
          .receive("error", () => {
            ctx.addSystemMessage("Failed to update thinking budget on server.");
          });
      }
      ctx.addSystemMessage(pc.dim("Extended thinking disabled"));
      return;
    }

    const budget = arg ? parseInt(arg, 10) : DEFAULT_BUDGET;
    if (isNaN(budget) || budget <= 0) {
      ctx.addSystemMessage(
        pc.red(`Invalid budget "${args.trim()}". Use a positive integer or "off".`),
      );
      return;
    }

    useAppStore.getState().setThinkingBudget(budget);
    const channel = getSessionChannel();
    if (channel) {
      channel
        .push("set_thinking_budget", { budget })
        .receive("error", () => {
          ctx.addSystemMessage("Failed to update thinking budget on server.");
        });
    }

    ctx.addSystemMessage(
      pc.cyan("Extended thinking enabled") +
        pc.dim(` — budget: ${budget.toLocaleString()} tokens`),
    );
  },
});
