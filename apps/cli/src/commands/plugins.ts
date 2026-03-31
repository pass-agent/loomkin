import pc from "picocolors";
import { register } from "./registry.js";
import { getLoadedPlugins } from "../lib/plugins.js";

register({
  name: "plugins",
  description: "List installed plugins",
  handler: (_args, ctx) => {
    const plugins = getLoadedPlugins();

    if (plugins.length === 0) {
      ctx.addSystemMessage(
        pc.dim(
          "No plugins loaded. Add .js files to ~/.loomkin/plugins/ to install plugins.",
        ),
      );
      return;
    }

    const lines: string[] = [pc.bold(`Plugins (${plugins.length}):`)];
    for (const plugin of plugins) {
      const filename = plugin.filePath.split("/").pop() ?? plugin.filePath;
      const statusIcon = plugin.status === "loaded" ? pc.green("✔") : pc.red("✖");

      if (plugin.status === "loaded") {
        const cmdList =
          plugin.commands.length > 0
            ? plugin.commands.map((c) => pc.cyan(`/${c}`)).join(", ")
            : pc.dim("(no commands registered)");
        lines.push(`  ${statusIcon} ${pc.bold(filename)} — ${cmdList}`);
      } else {
        lines.push(
          `  ${statusIcon} ${pc.bold(filename)} — ${pc.red(plugin.error ?? "error")}`,
        );
      }
      lines.push(pc.dim(`    ${plugin.filePath}`));
    }

    ctx.addSystemMessage(lines.join("\n"));
  },
});
