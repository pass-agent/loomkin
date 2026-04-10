import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getSettings, updateSettings, ApiError } from "../lib/api.js";
import type { Setting } from "../lib/types.js";

function typeBadge(type: string): string {
  return pc.dim(`[${type}]`);
}

function formatValue(setting: Setting): string {
  const val = setting.value;
  const isDefault = JSON.stringify(val) === JSON.stringify(setting.default);
  const unit = setting.unit ? pc.dim(` ${setting.unit}`) : "";

  if (setting.type === "toggle") {
    const label = val ? "on" : "off";
    return isDefault ? pc.green(label) : pc.yellow(label);
  }

  if (setting.type === "tag_list" && Array.isArray(val)) {
    const tags = val.length > 0 ? val.join(", ") : pc.dim("(empty)");
    return isDefault ? tags : pc.yellow(tags);
  }

  const str = String(val);
  return isDefault ? str + unit : pc.yellow(str) + unit;
}

function parseValueForType(type: string, raw: string, setting: Setting): unknown {
  switch (type) {
    case "toggle": {
      const lower = raw.toLowerCase();
      if (["true", "1", "on", "yes"].includes(lower)) return true;
      if (["false", "0", "off", "no"].includes(lower)) return false;
      throw new Error(`Invalid toggle value "${raw}". Use true/false, on/off, 1/0.`);
    }
    case "number":
    case "duration":
    case "currency": {
      const num = Number(raw);
      if (Number.isNaN(num)) throw new Error(`Invalid number "${raw}".`);
      if (setting.range) {
        if (num < setting.range.min || num > setting.range.max) {
          throw new Error(`Value must be between ${setting.range.min} and ${setting.range.max}.`);
        }
      }
      return num;
    }
    case "select": {
      if (setting.options && !setting.options.includes(raw)) {
        throw new Error(`Invalid option "${raw}". Choose from: ${setting.options.join(", ")}`);
      }
      return raw;
    }
    case "tag_list":
      return raw
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
    default:
      return raw;
  }
}

function showTabs(settings: Setting[], ctx: CommandContext): void {
  const tabs = new Map<string, number>();
  for (const s of settings) {
    tabs.set(s.tab, (tabs.get(s.tab) ?? 0) + 1);
  }

  const lines = [pc.bold("Settings Tabs"), ""];
  for (const [tab, count] of tabs) {
    lines.push(`  ${pc.cyan(tab)} ${pc.dim(`(${count} settings)`)}`);
  }
  lines.push("", pc.dim("Usage: /settings <tab> to browse a tab"));
  ctx.addSystemMessage(lines.join("\n"));
}

function showTab(settings: Setting[], tabName: string, ctx: CommandContext): void {
  const tab = settings.filter((s) => s.tab.toLowerCase() === tabName.toLowerCase());

  if (tab.length === 0) {
    const available = [...new Set(settings.map((s) => s.tab))].join(", ");
    ctx.addSystemMessage(`Unknown tab "${tabName}". Available: ${available}`);
    return;
  }

  const sections = new Map<string, Setting[]>();
  for (const s of tab) {
    const list = sections.get(s.section) ?? [];
    list.push(s);
    sections.set(s.section, list);
  }

  const lines = [pc.bold(tab[0].tab), ""];
  for (const [section, items] of sections) {
    lines.push(`  ${pc.bold(pc.underline(section))}`);
    for (const s of items) {
      const key = s.key.split(".").pop() ?? s.key;
      lines.push(`    ${typeBadge(s.type)} ${pc.cyan(key)}: ${formatValue(s)}`);
    }
    lines.push("");
  }
  lines.push(pc.dim("Usage: /settings <key> for details, /settings <key>=<value> to update"));
  ctx.addSystemMessage(lines.join("\n"));
}

function showDetail(settings: Setting[], key: string, ctx: CommandContext): void {
  const setting = settings.find((s) => s.key === key || s.key.endsWith(`.${key}`));

  if (!setting) {
    ctx.addSystemMessage(`Setting "${key}" not found. Try ${pc.cyan("/settings search")} <query>`);
    return;
  }

  const lines = [
    pc.bold(setting.label),
    pc.dim(setting.description),
    "",
    `  ${pc.dim("Key:")}     ${setting.key}`,
    `  ${pc.dim("Type:")}    ${setting.type}`,
    `  ${pc.dim("Value:")}   ${formatValue(setting)}`,
    `  ${pc.dim("Default:")} ${String(setting.default)}${setting.unit ? ` ${setting.unit}` : ""}`,
  ];

  if (setting.range) {
    lines.push(
      `  ${pc.dim("Range:")}   ${setting.range.min}–${setting.range.max}${setting.step ? ` (step ${setting.step})` : ""}`,
    );
  }
  if (setting.options) {
    lines.push(`  ${pc.dim("Options:")} ${setting.options.join(", ")}`);
  }

  ctx.addSystemMessage(lines.join("\n"));
}

function searchSettings(settings: Setting[], query: string, ctx: CommandContext): void {
  const q = query.toLowerCase();
  const matches = settings.filter(
    (s) =>
      s.key.toLowerCase().includes(q) ||
      s.label.toLowerCase().includes(q) ||
      s.description.toLowerCase().includes(q),
  );

  if (matches.length === 0) {
    ctx.addSystemMessage(`No settings matching "${query}".`);
    return;
  }

  const limit = 15;
  const shown = matches.slice(0, limit);
  const lines = [pc.bold(`Settings matching "${query}"`), ""];
  for (const s of shown) {
    lines.push(`  ${pc.dim(s.tab + " >")} ${pc.cyan(s.key)}: ${formatValue(s)}`);
  }
  if (matches.length > limit) {
    lines.push(pc.dim(`  ... and ${matches.length - limit} more`));
  }

  ctx.addSystemMessage(lines.join("\n"));
}

register({
  name: "settings",
  aliases: ["set"],
  description: "View and edit server settings",
  args: "[tab|key|key=value|search <query>]",
  handler: async (args: string, ctx: CommandContext) => {
    const trimmed = args.trim();

    let settings: Setting[];
    try {
      const response = await getSettings();
      settings = response.settings;
    } catch (err) {
      const msg =
        err instanceof ApiError
          ? `Failed to fetch settings: ${err.body}`
          : "Failed to fetch settings.";
      ctx.addSystemMessage(pc.red(msg));
      return;
    }

    // No args → show tabs
    if (!trimmed) {
      showTabs(settings, ctx);
      return;
    }

    // /settings search <query>
    if (trimmed.startsWith("search ")) {
      searchSettings(settings, trimmed.slice(7).trim(), ctx);
      return;
    }

    // /settings key=value → update
    if (trimmed.includes("=")) {
      const eqIndex = trimmed.indexOf("=");
      const key = trimmed.slice(0, eqIndex).trim();
      const rawValue = trimmed.slice(eqIndex + 1).trim();

      const setting = settings.find((s) => s.key === key || s.key.endsWith(`.${key}`));
      if (!setting) {
        ctx.addSystemMessage(`Setting "${key}" not found.`);
        return;
      }

      let parsed: unknown;
      try {
        parsed = parseValueForType(setting.type, rawValue, setting);
      } catch (err) {
        ctx.addSystemMessage(pc.red(err instanceof Error ? err.message : String(err)));
        return;
      }

      try {
        await updateSettings({ [setting.key]: parsed });
        ctx.addSystemMessage(
          `${pc.green("Updated")} ${pc.cyan(setting.key)} → ${pc.bold(String(parsed))}`,
        );
      } catch (err) {
        if (err instanceof ApiError && err.status === 422) {
          try {
            const body = JSON.parse(err.body) as {
              errors?: Record<string, string>;
            };
            const messages = body.errors ? Object.values(body.errors).join("; ") : err.body;
            ctx.addSystemMessage(pc.red(`Validation error: ${messages}`));
          } catch {
            ctx.addSystemMessage(pc.red(`Validation error: ${err.body}`));
          }
        } else {
          ctx.addSystemMessage(pc.red("Failed to update setting."));
        }
        return;
      }
      return;
    }

    // Contains dot → setting detail
    if (trimmed.includes(".")) {
      showDetail(settings, trimmed, ctx);
      return;
    }

    // Otherwise → show tab
    showTab(settings, trimmed, ctx);
  },
});

export { parseValueForType, formatValue, typeBadge };
