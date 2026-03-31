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
      channel.push("set_plan_mode", { enabled: enable });
    }

    useAppStore.getState().setPlanMode(enable);

    if (enable) {
      ctx.addSystemMessage(
        pc.cyan("Plan mode enabled") +
          " — Claude will present a plan for approval before executing",
      );
    } else {
      ctx.addSystemMessage(
        pc.dim("Plan mode disabled") +
          " — Claude will execute without a planning step",
      );
    }
  },
});
