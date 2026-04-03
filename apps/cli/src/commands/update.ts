import pc from "picocolors";
import { register } from "./registry.js";
import { getUpdateAvailable } from "../lib/updater.js";

// Package version — must match package.json
const CURRENT_VERSION = "0.1.0";

register({
  name: "update",
  description: "Check for and install updates",
  handler: (_args, ctx) => {
    const available = getUpdateAvailable();
    const lines: string[] = [pc.bold("loomkin update"), ""];

    lines.push(`  Current version:  ${pc.bold(CURRENT_VERSION)}`);

    if (available) {
      lines.push(`  Latest version:   ${pc.bold(pc.green(available))}`);
      lines.push("");
      lines.push(pc.green("  A new version is available!"));
      lines.push(
        pc.dim("  To update, run:") +
          pc.bold("  bun update -g @loomkin/cli"),
      );
    } else {
      lines.push(
        `  Latest version:   ${pc.dim("(checking in background...)")}`,
      );
      lines.push("");
      lines.push(pc.dim("  Version check still in progress. Try again shortly."));
    }

    lines.push("");
    lines.push(pc.dim("  Set NO_UPDATE_CHECK=1 to disable version checks."));

    ctx.addSystemMessage(lines.join("\n"));
  },
});
