import pc from "picocolors";
import { register } from "./registry.js";
import type { CommandContext } from "./registry.js";
import { getOAuthStatus, disconnectOAuth } from "../lib/api.js";
import { runOAuthFlow } from "../lib/oauth.js";
import { extractErrorMessage } from "../lib/errors.js";

const OAUTH_PROVIDERS = [
  { id: "anthropic", name: "Anthropic" },
  { id: "google", name: "Google" },
  { id: "openai", name: "OpenAI" },
] as const;

type OAuthProviderId = (typeof OAUTH_PROVIDERS)[number]["id"];

function resolveProvider(input: string): { id: OAuthProviderId; name: string } | null {
  const lower = input.toLowerCase();
  return OAUTH_PROVIDERS.find(
    (p) => p.id === lower || p.name.toLowerCase() === lower,
  ) ?? null;
}

register({
  name: "provider",
  aliases: ["oauth"],
  description: "Connect or disconnect OAuth providers (Anthropic, Google, OpenAI)",
  args: "[connect [name] | disconnect <name> | status]",
  handler: async (_args: string, ctx: CommandContext) => {
    const parts = _args.trim().split(/\s+/);
    const subcommand = parts[0]?.toLowerCase() ?? "";
    const providerArg = parts[1] ?? "";

    if (!subcommand || subcommand === "status") {
      await showAllStatuses(ctx);
      return;
    }

    if (subcommand === "connect") {
      if (!providerArg) {
        ctx.addSystemMessage(
          [
            pc.bold("Usage:") + " /provider connect <name>",
            "",
            `  Providers: ${OAUTH_PROVIDERS.map((p) => p.id).join(", ")}`,
            "",
            pc.dim("Tip: Use ctrl+o inside the model picker to connect via OAuth."),
          ].join("\n"),
        );
        return;
      }

      const prov = resolveProvider(providerArg);
      if (!prov) {
        ctx.addSystemMessage(
          pc.red(
            `Unknown provider "${providerArg}". Available: ${OAUTH_PROVIDERS.map((p) => p.id).join(", ")}`,
          ),
        );
        return;
      }
      const ok = await runOAuthFlow(prov.id, prov.name);
      ctx.addSystemMessage(
        ok
          ? pc.green(`${prov.name} connected. You can now use ${prov.name} models.`)
          : pc.red(`Failed to connect ${prov.name}.`),
      );
      return;
    }

    if (subcommand === "disconnect") {
      const prov = resolveProvider(providerArg);
      if (!prov) {
        ctx.addSystemMessage(
          pc.red(
            `Unknown provider "${providerArg}". Available: ${OAUTH_PROVIDERS.map((p) => p.id).join(", ")}`,
          ),
        );
        return;
      }
      try {
        await disconnectOAuth(prov.id);
        ctx.addSystemMessage(pc.green(`${prov.name} disconnected.`));
      } catch (err) {
        ctx.addSystemMessage(
          pc.red(`Failed to disconnect ${prov.name}: ${extractErrorMessage(err)}`),
        );
      }
      return;
    }

    ctx.addSystemMessage(
      [
        pc.bold("Provider Commands"),
        "",
        `  ${pc.cyan("/provider")}                   Show all OAuth provider statuses`,
        `  ${pc.cyan("/provider connect")}            Interactive provider selection`,
        `  ${pc.cyan("/provider connect <name>")}     Connect a specific provider`,
        `  ${pc.cyan("/provider disconnect <name>")}  Disconnect a provider`,
        "",
        `  Providers: anthropic, google, openai`,
      ].join("\n"),
    );
  },
});

async function showAllStatuses(ctx: CommandContext): Promise<void> {
  const results = await Promise.all(
    OAUTH_PROVIDERS.map(async (prov) => {
      try {
        const s = await getOAuthStatus(prov.id);
        return { ...prov, connected: s.connected, flow_active: s.flow_active };
      } catch {
        return { ...prov, connected: false, flow_active: false };
      }
    }),
  );

  const lines = [pc.bold("OAuth Provider Status"), ""];
  for (const r of results) {
    const dot = r.connected ? pc.green("✔") : pc.dim("○");
    const status = r.connected ? pc.green("connected") : pc.dim("not connected");
    const pending =
      r.flow_active && !r.connected ? pc.yellow(" (flow active...)") : "";
    lines.push(`  ${dot} ${r.name.padEnd(12)} ${status}${pending}`);
  }
  lines.push("");
  lines.push(
    pc.dim(
      "Use /provider connect <name> to connect, /provider disconnect <name> to revoke.",
    ),
  );
  ctx.addSystemMessage(lines.join("\n"));
}
