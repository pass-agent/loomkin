import { register, type CommandContext } from "./registry.js";
import { themeList, getTheme } from "../lib/themes.js";
import { useThemeStore } from "../stores/themeStore.js";

function preview(name: string): string {
  const t = getTheme(name);
  const lines = [
    `  ${t.bold(t.label)}  ${t.dim(t.description)}`,
    `  ${t.success("✔ success")}  ${t.error("✖ error")}  ${t.warning("⚠ warning")}  ${t.info("ℹ info")}`,
    `  ${t.agentWorking("● working")}  ${t.agentIdle("○ idle")}  ${t.agentBlocked("◉ blocked")}  ${t.agentError("✖ error")}`,
    `  ${t.userName("User")} → ${t.assistantName("Assistant")} → ${t.toolName("tool_call")} → ${t.roleName("researcher")}`,
  ];
  return lines.join("\n");
}

register({
  name: "theme",
  description: "Switch color theme",
  args: "[theme-name | list | preview]",
  handler: (_args: string, ctx: CommandContext) => {
    const arg = _args.trim();
    const current = useThemeStore.getState().theme;

    // /theme — show current + list
    if (!arg || arg === "list") {
      const lines = themeList.map((t) => {
        const marker = t.name === current.name ? t.success("▸ ") : "  ";
        const cb = t.colorblind ? t.dim(" [colorblind-friendly]") : "";
        return `${marker}${t.bold(t.name)}  ${t.dim(t.description)}${cb}`;
      });

      const header = current.bold(`Current theme: ${current.name}`);
      const hint = current.dim("  Switch with: /theme <name>");
      ctx.addSystemMessage(`${header}\n\n${lines.join("\n")}\n\n${hint}`);
      return;
    }

    // /theme preview [name] — show color swatches
    if (arg === "preview" || arg.startsWith("preview ")) {
      const name = arg.replace("preview", "").trim();
      if (name) {
        const t = getTheme(name);
        if (t.name === "default" && name !== "default") {
          ctx.addSystemMessage(current.error(`Unknown theme: ${name}`));
          return;
        }
        ctx.addSystemMessage(preview(name));
      } else {
        // Preview all
        const previews = themeList.map((t) => preview(t.name));
        ctx.addSystemMessage(previews.join("\n\n"));
      }
      return;
    }

    // /theme <name> — switch theme
    const theme = getTheme(arg);
    if (theme.name === "default" && arg !== "default") {
      ctx.addSystemMessage(
        current.error(`Unknown theme "${arg}". Use /theme list to see options.`),
      );
      return;
    }

    useThemeStore.getState().setTheme(arg);
    ctx.addSystemMessage(
      `${theme.success("✔")} Switched to ${theme.bold(theme.label)} theme\n\n${preview(arg)}`,
    );
  },
});
