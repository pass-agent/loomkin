import pc from "picocolors";
import { register } from "./registry.js";
import { useAppStore } from "../stores/appStore.js";
import { getSessionChannel } from "./channelUtil.js";

register({
  name: "plan",
  description: "Toggle plan mode (require approval before execution)",
  args: "[on|off]",
  handler: (args, ctx) => {
    const arg = args.trim().toLowerCase();
    const currentPlanMode = useAppStore.getState().planMode;

    // Determine new state
    let enable: boolean;
    if (arg === "on") {
      enable = true;
    } else if (arg === "off") {
      enable = false;
    } else {
      // Toggle
      enable = !currentPlanMode;
    }

    const channel = getSessionChannel();
    if (channel) {
      channel.push("set_plan_mode", { enabled: enable }).receive("error", () => {
        ctx.addSystemMessage("Failed to set plan mode on server — local state updated only.");
      });
    }

    useAppStore.getState().setPlanMode(enable);

    const model = useAppStore.getState().model;
    const modelLabel = model
      ? model.includes(":")
        ? model.split(":")[1]
        : model
      : "the assistant";

    if (enable) {
      ctx.addSystemMessage(
        pc.cyan("Plan mode enabled") +
          ` — ${modelLabel} will present a plan for approval before executing`,
      );
    } else {
      ctx.addSystemMessage(
        pc.dim("Plan mode disabled") + ` — ${modelLabel} will execute without a planning step`,
      );
    }
  },
});
