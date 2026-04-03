import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getApiBaseUrl } from "../lib/urls.js";

const SUBCOMMANDS = ["auth", "list", "attach", "detach", "search", "status"] as const;
type Subcommand = (typeof SUBCOMMANDS)[number];

function parseSubcommand(args: string): { sub: Subcommand | null; rest: string } {
  const [first, ...rest] = args.trim().split(/\s+/);
  const sub = first?.toLowerCase() as Subcommand;
  if (SUBCOMMANDS.includes(sub)) {
    return { sub, rest: rest.join(" ") };
  }
  return { sub: null, rest: args };
}

// --- Subcommand handlers ---

async function vaultAuth(ctx: CommandContext) {
  const lines: string[] = [
    pc.bold("Vault Authentication"),
    "",
    `This will open ${pc.cyan("loomkin.dev")} in your browser to sign in.`,
    "",
    pc.dim("Once authenticated, the CLI will store your token locally"),
    pc.dim("and you can list and attach vaults."),
    "",
  ];

  // TODO: implement OAuth flow once loomkin.dev API is live
  lines.push(
    pc.yellow("⚠ loomkin.dev API is not yet available."),
    pc.dim("  This command will work once the remote API is deployed."),
  );

  ctx.addSystemMessage(lines.join("\n"));
}

async function vaultList(ctx: CommandContext) {
  const lines: string[] = [
    pc.bold("Your Vaults"),
    "",
  ];

  // TODO: call GET /api/v1/vaults once loomkin.dev API is live
  // For now, query local vaults via the Phoenix API
  try {
    const res = await fetch(`${getApiBaseUrl()}/api/vaults`, {
      headers: { "content-type": "application/json" },
    });

    if (res.ok) {
      const { vaults } = (await res.json()) as { vaults: VaultSummary[] };
      if (vaults.length === 0) {
        lines.push(pc.dim("  No vaults found."));
        lines.push("");
        lines.push(pc.dim("  Create a vault at loomkin.dev, then /vault attach <id>"));
      } else {
        for (const v of vaults) {
          const storage = pc.dim(`[${v.storage_type}]`);
          const entries = v.entry_count != null ? pc.dim(`${v.entry_count} entries`) : "";
          lines.push(`  ${pc.cyan(v.vault_id)} ${v.name} ${storage} ${entries}`);
        }
      }
    } else {
      lines.push(pc.dim("  Unable to fetch vaults from server."));
      lines.push(pc.dim("  Make sure loomkin-server is running."));
    }
  } catch {
    lines.push(pc.dim("  Unable to connect to server."));
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

  const lines: string[] = [
    pc.bold("Attaching Vault"),
    "",
    `  Vault: ${pc.cyan(vaultId)}`,
    "",
  ];

  // TODO: verify vault exists via API, write .loomkin/vault.json
  // For now, send as a message to the agent so it can use vault tools
  lines.push(
    pc.yellow("⚠ Remote vault attach is not yet implemented."),
    "",
    pc.dim("  For now, agents can use vault tools directly with this vault_id."),
    pc.dim("  The vault must exist in the local database."),
  );

  ctx.addSystemMessage(lines.join("\n"));
}

async function vaultDetach(ctx: CommandContext) {
  // TODO: remove .loomkin/vault.json
  ctx.addSystemMessage(
    pc.yellow("⚠ Vault detach is not yet implemented.") +
      "\n" +
      pc.dim("  This will remove the vault attachment from the current project."),
  );
}

async function vaultSearch(query: string, ctx: CommandContext) {
  if (!query) {
    ctx.addSystemMessage(pc.red("Usage: /vault search <query>"));
    return;
  }

  // Send the search query as a user message so the agent can use vault_search
  ctx.sendMessage(`Search the vault for: ${query}`);
}

async function vaultStatus(ctx: CommandContext) {
  const lines: string[] = [
    pc.bold("Vault Status"),
    "",
  ];

  // Check local server for vault info
  try {
    const res = await fetch(`${getApiBaseUrl()}/api/vaults`, {
      headers: { "content-type": "application/json" },
    });

    if (res.ok) {
      const { vaults } = (await res.json()) as { vaults: VaultSummary[] };
      if (vaults.length === 0) {
        lines.push(pc.dim("  No vaults configured."));
        lines.push("");
        lines.push(pc.dim("  1. Create a vault at loomkin.dev"));
        lines.push(pc.dim("  2. Run /vault attach <vault-id>"));
      } else {
        lines.push(pc.bold(pc.underline("  Local Vaults")));
        for (const v of vaults) {
          const storage = pc.dim(`[${v.storage_type}]`);
          lines.push(`  ${pc.cyan(v.vault_id)} ${v.name} ${storage}`);
          if (v.entry_count != null) {
            lines.push(`    ${pc.dim(`${v.entry_count} entries`)}`);
          }
        }
      }
    } else {
      lines.push(pc.dim("  Server not reachable."));
    }
  } catch {
    lines.push(pc.dim("  Unable to connect to server."));
  }

  // Auth status
  lines.push("");
  lines.push(pc.bold(pc.underline("  Authentication")));
  // TODO: check ~/.config/loomkin/auth.json
  lines.push(pc.dim("  Not authenticated with loomkin.dev"));
  lines.push(pc.dim("  Run /vault auth to connect"));

  lines.push("");
  ctx.addSystemMessage(lines.join("\n"));
}

function showHelp(ctx: CommandContext) {
  const lines = [
    pc.bold("Vault Commands"),
    "",
    `  ${pc.cyan("/vault auth")}     ${pc.dim("Authenticate with loomkin.dev")}`,
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
  storage_type: string;
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
