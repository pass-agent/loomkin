import { existsSync, mkdirSync, readdirSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { register, BUILTIN_COMMANDS, markCurrentAsBuiltins } from "../commands/registry.js";
import type { SlashCommand } from "../commands/registry.js";
import { logger } from "./logger.js";

export interface LoadedPlugin {
  filePath: string;
  commands: string[];
  status: "loaded" | "error";
  error?: string;
}

const loadedPlugins: LoadedPlugin[] = [];

function getPluginsDir(): string {
  return join(homedir(), ".loomkin", "plugins");
}

function ensurePluginsDir(): void {
  const dir = getPluginsDir();
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
}

function isValidCommand(cmd: unknown): cmd is SlashCommand {
  if (typeof cmd !== "object" || cmd === null) return false;
  const c = cmd as Record<string, unknown>;
  return typeof c.name === "string" && typeof c.handler === "function";
}

/**
 * Load all plugin files from ~/.loomkin/plugins/*.js
 * Each plugin must export a default array of SlashCommand or a single SlashCommand.
 */
export async function loadPlugins(): Promise<void> {
  // Mark all currently registered commands as built-in before loading plugins
  markCurrentAsBuiltins();

  ensurePluginsDir();
  const dir = getPluginsDir();
  let files: string[] = [];

  try {
    files = readdirSync(dir)
      .filter((f) => f.endsWith(".js"))
      .sort();
  } catch {
    return;
  }

  const MAX_PLUGIN_FILES = 50;
  if (files.length > MAX_PLUGIN_FILES) {
    logger.debug(
      `[plugins] found ${files.length} plugin files — loading first ${MAX_PLUGIN_FILES} only`,
    );
    files = files.slice(0, MAX_PLUGIN_FILES);
  }

  const resolvedDir = await Bun.file(dir).exists() ? (await Bun.resolve(".", dir)) : dir;

  for (const file of files) {
    const filePath = join(dir, file);

    // Ensure resolved path stays within the plugins directory (prevent symlink escape)
    const resolved = await Bun.resolve(filePath, ".");
    if (!resolved.startsWith(resolvedDir)) {
      logger.debug(`[plugins] ${file}: path escapes plugins directory — skipping`);
      continue;
    }

    const plugin: LoadedPlugin = { filePath, commands: [], status: "loaded" };

    try {
      const mod = await import(filePath);
      const exported = mod.default;

      if (!exported) {
        plugin.status = "error";
        plugin.error = "plugin has no default export";
        loadedPlugins.push(plugin);
        continue;
      }

      const candidates: unknown[] = Array.isArray(exported) ? exported : [exported];

      for (const candidate of candidates) {
        if (!isValidCommand(candidate)) {
          logger.debug(`[plugins] ${file}: skipping invalid command (missing name or handler)`);
          continue;
        }

        const cmd = candidate as SlashCommand;

        // Protect built-in commands from being overridden
        if (BUILTIN_COMMANDS.has(cmd.name)) {
          logger.debug(
            `[plugins] ${file}: skipping "${cmd.name}" — conflicts with built-in command`,
          );
          continue;
        }

        register(cmd);
        plugin.commands.push(cmd.name);
      }

      loadedPlugins.push(plugin);
    } catch (err) {
      plugin.status = "error";
      plugin.error = err instanceof Error ? err.message : String(err);
      loadedPlugins.push(plugin);
      logger.debug(`[plugins] failed to load ${file}: ${plugin.error}`);
    }
  }
}

/**
 * Returns the list of plugins attempted to load with their status.
 */
export function getLoadedPlugins(): LoadedPlugin[] {
  return loadedPlugins;
}
