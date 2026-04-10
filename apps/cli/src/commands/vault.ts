import pc from "picocolors";
import { join } from "path";
import { register, type CommandContext } from "./registry.js";
import { getApiBaseUrl } from "../lib/urls.js";
import { isCloudAuthenticated, getCloudAuth, clearCloudAuth } from "../lib/cloudConfig.js";
import { listVaults, getVault, searchVault, getCloudBaseUrl } from "../lib/cloudApi.js";
import { runDeviceCodeFlow } from "../lib/deviceCodeFlow.js";

const SUBCOMMANDS = ["auth", "list", "attach", "detach", "search", "status", "logout"] as const;
type Subcommand = (typeof SUBCOMMANDS)[number];

const VAULT_CONFIG_NAME = "vault.json";
const LOOMKIN_DIR = ".loomkin";

function parseSubcommand(args: string): { sub: Subcommand | null; rest: string } {
  const [first, ...rest] = args.trim().split(/\s+/);
  const sub = first?.toLowerCase() as Subcommand;
  if (SUBCOMMANDS.includes(sub)) {
    return { sub, rest: rest.join(" ") };
  }
  return { sub: null, rest: args };
}

function getVaultConfigPath(): string {
  return join(process.cwd(), LOOMKIN_DIR, VAULT_CONFIG_NAME);
}

interface VaultConfig {
  vault_id: string;
  name: string;
  server: string;
  attached_at: string;
}

async function readVaultConfig(): Promise<VaultConfig | null> {
  try {
    const file = Bun.file(getVaultConfigPath());
    if (!(await file.exists())) return null;
    return (await file.json()) as VaultConfig;
  } catch {
    return null;
  }
}

async function writeVaultConfig(config: VaultConfig): Promise<void> {
  const dir = join(process.cwd(), LOOMKIN_DIR);
  // Ensure .loomkin directory exists
  const { mkdir } = await import("fs/promises");
  await mkdir(dir, { recursive: true });
  await Bun.write(getVaultConfigPath(), JSON.stringify(config, null, 2) + "\n");
}

async function removeVaultConfig(): Promise<boolean> {
  try {
    const { unlink } = await import("fs/promises");
    await unlink(getVaultConfigPath());
    return true;
  } catch {
    return false;
  }
}

// --- Subcommand handlers ---

async function vaultAuth(ctx: CommandContext) {
  if (isCloudAuthenticated()) {
    const auth = getCloudAuth();
    ctx.addSystemMessage(
      pc.green("Already authenticated with loomkin.dev") +
        "\n" +
        pc.dim(`Token expires: ${auth?.expiresAt}`) +
        "\n\n" +
        pc.dim("Run /vault logout to disconnect."),
    );
    return;
  }

  await runDeviceCodeFlow((msg) => ctx.addSystemMessage(msg));
}

async function vaultLogout(ctx: CommandContext) {
  if (!isCloudAuthenticated()) {
    ctx.addSystemMessage(pc.dim("Not currently authenticated with loomkin.dev."));
    return;
  }

  clearCloudAuth();
  ctx.addSystemMessage(pc.green("Logged out of loomkin.dev."));
}

async function vaultList(ctx: CommandContext) {
  if (!isCloudAuthenticated()) {
    ctx.addSystemMessage(
      pc.yellow("Not authenticated with loomkin.dev.") +
        "\n" +
        pc.dim("Run /vault auth to connect."),
    );
    return;
  }

  const lines: string[] = [pc.bold("Your Vaults"), ""];

  try {
    const { vaults } = await listVaults();
    if (vaults.length === 0) {
      lines.push(pc.dim("  No vaults found."));
      lines.push("");
      lines.push(pc.dim("  Create a vault at loomkin.dev, then /vault attach <id>"));
    } else {
      // Table header
      lines.push(
        `  ${pc.bold(pc.underline("ID"))}${" ".repeat(34)}${pc.bold(pc.underline("Name"))}${" ".repeat(16)}${pc.bold(pc.underline("Entries"))}`,
      );
      for (const v of vaults) {
        const id = v.vault_id.padEnd(36);
        const name = (v.name.length > 18 ? v.name.slice(0, 17) + "\u2026" : v.name).padEnd(20);
        const entries = String(v.entry_count);
        lines.push(`  ${pc.cyan(id)}${name}${entries}`);
      }
    }
  } catch (err) {
    lines.push(
      pc.red("  Failed to fetch vaults: ") + (err instanceof Error ? err.message : "Unknown error"),
    );
  }

  lines.push("");
  ctx.addSystemMessage(lines.join("\n"));
}

async function vaultAttach(vaultId: string, ctx: CommandContext) {
  if (!vaultId) {
    ctx.addSystemMessage(
      pc.red("Usage: /vault attach <vault-id>") +
        "\n" +
        pc.dim("Run /vault list to see available vaults."),
    );
    return;
  }

  if (!isCloudAuthenticated()) {
    ctx.addSystemMessage(
      pc.yellow("Not authenticated with loomkin.dev.") + "\n" + pc.dim("Run /vault auth first."),
    );
    return;
  }

  // Verify vault exists and user has access
  let vault;
  try {
    const result = await getVault(vaultId);
    vault = result.vault;
  } catch (err) {
    ctx.addSystemMessage(
      pc.red("Could not access vault: ") + (err instanceof Error ? err.message : "Unknown error"),
    );
    return;
  }

  await writeVaultConfig({
    vault_id: vault.vault_id,
    name: vault.name,
    server: getCloudBaseUrl(),
    attached_at: new Date().toISOString(),
  });

  ctx.addSystemMessage(
    [
      pc.green(`Vault attached: ${vault.name}`),
      "",
      `  ${pc.dim("ID:")}     ${pc.cyan(vault.vault_id)}`,
      `  ${pc.dim("Server:")} ${getCloudBaseUrl()}`,
      `  ${pc.dim("Config:")} ${getVaultConfigPath()}`,
      "",
      pc.dim("Agents in this project can now access this vault."),
    ].join("\n"),
  );
}

async function vaultDetach(ctx: CommandContext) {
  const existing = await readVaultConfig();
  if (!existing) {
    ctx.addSystemMessage(pc.dim("No vault attached to this project."));
    return;
  }

  const removed = await removeVaultConfig();
  if (removed) {
    ctx.addSystemMessage(
      pc.green(`Vault detached: ${existing.name}`) +
        "\n" +
        pc.dim(`Removed ${getVaultConfigPath()}`),
    );
  } else {
    ctx.addSystemMessage(pc.red("Failed to remove vault config."));
  }
}

async function vaultSearch(query: string, ctx: CommandContext) {
  if (!query) {
    ctx.addSystemMessage(pc.red("Usage: /vault search <query>"));
    return;
  }

  // Try cloud search if authenticated and vault is attached
  const vaultConfig = await readVaultConfig();
  if (isCloudAuthenticated() && vaultConfig) {
    try {
      const { results } = await searchVault(vaultConfig.vault_id, query);
      if (results.length > 0) {
        const lines = [pc.bold(`Vault search: "${query}"`), ""];
        for (const r of results) {
          const tags = r.tags.length > 0 ? pc.dim(` [${r.tags.join(", ")}]`) : "";
          lines.push(`  ${pc.cyan(r.title)} ${pc.dim(`(${r.entry_type})`)}${tags}`);
          lines.push(`    ${pc.dim(r.path)}`);
        }
        lines.push("");
        ctx.addSystemMessage(lines.join("\n"));
        return;
      }
    } catch {
      // Fall through to agent-based search
    }
  }

  // Delegate to agent
  ctx.sendMessage(`Search the vault for: ${query}`);
}

async function vaultStatus(ctx: CommandContext) {
  const lines: string[] = [pc.bold("Vault Status"), ""];

  // Cloud auth status
  lines.push(pc.bold(pc.underline("  Authentication")));
  if (isCloudAuthenticated()) {
    const auth = getCloudAuth();
    lines.push(`  ${pc.green("Connected")} to ${pc.cyan(auth?.serverUrl ?? "loomkin.dev")}`);
    lines.push(`  ${pc.dim("Scope:")}   ${auth?.scope}`);
    lines.push(`  ${pc.dim("Expires:")} ${auth?.expiresAt}`);
  } else {
    const auth = getCloudAuth();
    if (auth && new Date(auth.expiresAt) <= new Date()) {
      lines.push(`  ${pc.yellow("Token expired")} — run /vault auth to reconnect`);
    } else {
      lines.push(`  ${pc.dim("Not authenticated with loomkin.dev")}`);
      lines.push(`  ${pc.dim("Run /vault auth to connect")}`);
    }
  }

  lines.push("");

  // Vault attachment status
  lines.push(pc.bold(pc.underline("  Project Vault")));
  const vaultConfig = await readVaultConfig();
  if (vaultConfig) {
    lines.push(`  ${pc.green("Attached")}: ${pc.cyan(vaultConfig.name)}`);
    lines.push(`  ${pc.dim("ID:")}     ${vaultConfig.vault_id}`);
    lines.push(`  ${pc.dim("Server:")} ${vaultConfig.server}`);
    lines.push(`  ${pc.dim("Since:")}  ${vaultConfig.attached_at}`);

    // Fetch live details if authenticated
    if (isCloudAuthenticated()) {
      try {
        const { vault } = await getVault(vaultConfig.vault_id);
        lines.push(`  ${pc.dim("Entries:")} ${vault.entry_count}`);
        if (vault.description) {
          lines.push(`  ${pc.dim("Desc:")}    ${vault.description}`);
        }
      } catch {
        lines.push(`  ${pc.dim("(Could not fetch live details)")}`);
      }
    }
  } else {
    lines.push(`  ${pc.dim("No vault attached to this project.")}`);
    lines.push(`  ${pc.dim("Run /vault attach <vault-id> to connect one.")}`);
  }

  // Also show local server vaults if reachable
  try {
    const res = await fetch(`${getApiBaseUrl()}/api/vaults`, {
      headers: { "content-type": "application/json" },
    });
    if (res.ok) {
      const { vaults } = (await res.json()) as { vaults: VaultSummary[] };
      if (vaults.length > 0) {
        lines.push("");
        lines.push(pc.bold(pc.underline("  Local Vaults")));
        for (const v of vaults) {
          const entries = v.entry_count != null ? pc.dim(`${v.entry_count} entries`) : "";
          lines.push(`  ${pc.cyan(v.vault_id)} ${v.name} ${entries}`);
        }
      }
    }
  } catch {
    // Local server not running — that's fine
  }

  lines.push("");
  ctx.addSystemMessage(lines.join("\n"));
}

function showHelp(ctx: CommandContext) {
  const lines = [
    pc.bold("Vault Commands"),
    "",
    `  ${pc.cyan("/vault auth")}     ${pc.dim("Authenticate with loomkin.dev")}`,
    `  ${pc.cyan("/vault logout")}   ${pc.dim("Clear cloud authentication")}`,
    `  ${pc.cyan("/vault list")}     ${pc.dim("List accessible vaults")}`,
    `  ${pc.cyan("/vault attach")}   ${pc.dim("<vault-id> — Attach a vault to this project")}`,
    `  ${pc.cyan("/vault detach")}   ${pc.dim("Detach the current vault")}`,
    `  ${pc.cyan("/vault search")}   ${pc.dim("<query> — Search vault entries")}`,
    `  ${pc.cyan("/vault status")}   ${pc.dim("Show vault and auth status")}`,
    "",
  ];
  ctx.addSystemMessage(lines.join("\n"));
}

// --- Types ---

interface VaultSummary {
  vault_id: string;
  name: string;
  entry_count?: number;
}

// --- Registration ---

register({
  name: "vault",
  aliases: ["v"],
  description: "Manage knowledge vaults — auth, list, attach, search, status",
  args: "<subcommand> [args]",
  handler: async (args: string, ctx: CommandContext) => {
    const { sub, rest } = parseSubcommand(args);

    switch (sub) {
      case "auth":
        return vaultAuth(ctx);
      case "logout":
        return vaultLogout(ctx);
      case "list":
        return vaultList(ctx);
      case "attach":
        return vaultAttach(rest.trim(), ctx);
      case "detach":
        return vaultDetach(ctx);
      case "search":
        return vaultSearch(rest.trim(), ctx);
      case "status":
        return vaultStatus(ctx);
      default:
        return showHelp(ctx);
    }
  },
  getArgCompletions: (partial: string) => {
    return SUBCOMMANDS.filter((s) => s.startsWith(partial.toLowerCase()));
  },
});
