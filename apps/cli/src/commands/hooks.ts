import { register } from "./registry.js";
import { loadHooks } from "../lib/hooks.js";

register({
  name: "hooks",
  description: "List configured hooks",
  handler: (_args, ctx) => {
    const hooks = loadHooks();
    if (hooks.length === 0) {
      ctx.addSystemMessage("No hooks configured. Create ~/.loomkin/hooks.json");
      return;
    }
    hooks.forEach((h) => {
      ctx.addSystemMessage(
        `[${h.event}] ${h.command}${h.async ? " (async)" : ""}${h.timeout_ms ? ` (timeout: ${h.timeout_ms}ms)` : ""}`,
      );
    });
  },
});
