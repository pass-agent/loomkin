import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";

export interface HookDef {
  event: "PreToolUse" | "PostToolUse" | "SessionStart" | "SubagentStart";
  command: string;
  timeout_ms?: number;
  async?: boolean;
}

interface HooksConfig {
  hooks: HookDef[];
}

export interface HookOutput {
  continue?: boolean;
  decision?: "allow" | "deny";
  reason?: string;
  systemMessage?: string;
}

const HOOKS_CONFIG_PATH = join(homedir(), ".loomkin", "hooks.json");

export function loadHooks(): HookDef[] {
  if (!existsSync(HOOKS_CONFIG_PATH)) return [];
  try {
    const raw = readFileSync(HOOKS_CONFIG_PATH, "utf-8");
    const parsed = JSON.parse(raw) as HooksConfig;
    return parsed.hooks ?? [];
  } catch {
    return [];
  }
}

export async function runHooks(
  event: HookDef["event"],
  context: Record<string, unknown>,
): Promise<HookOutput[]> {
  const hooks = loadHooks().filter((h) => h.event === event);
  if (hooks.length === 0) return [];

  const results: HookOutput[] = [];

  for (const hook of hooks) {
    if (hook.async) {
      // Fire-and-forget: launch and don't await
      void spawnHook(hook, context).catch(() => {});
      continue;
    }

    const output = await spawnHook(hook, context);
    if (output) {
      results.push(output);
    }
  }

  return results;
}

async function spawnHook(
  hook: HookDef,
  context: Record<string, unknown>,
): Promise<HookOutput | null> {
  const timeoutMs = hook.timeout_ms ?? 30000;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    const proc = Bun.spawn(["sh", "-c", hook.command], {
      env: {
        ...process.env,
        HOOK_CONTEXT: JSON.stringify(context),
      },
      stdout: "pipe",
      stderr: "ignore",
      signal: controller.signal,
    });

    const stdout = await new Response(proc.stdout).text().finally(() => {
      clearTimeout(timer);
    });

    const exitCode = await proc.exited;
    if (exitCode !== 0) return null;

    const trimmed = stdout.trim();
    if (!trimmed) return null;

    try {
      return JSON.parse(trimmed) as HookOutput;
    } catch {
      return null;
    }
  } catch {
    return null;
  }
}
