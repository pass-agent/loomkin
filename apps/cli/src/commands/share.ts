import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { extractErrorMessage } from "../lib/errors.js";
import { createShare, listShares, revokeShare, type SessionShare } from "../lib/api.js";

function formatShare(share: SessionShare): string {
  const id = pc.dim(share.id.slice(0, 8));
  const perm = share.permission === "collaborate" ? pc.yellow("collab") : pc.green("view");
  const label = share.label ? pc.bold(share.label) : pc.dim("(no label)");
  const expires = share.expires_at
    ? pc.dim(new Date(share.expires_at).toLocaleDateString())
    : pc.dim("no expiry");

  return `  ${id}  ${perm}  ${label}  ${expires}`;
}

register({
  name: "share",
  description: "Create or manage live session share links",
  args: "[create|list|revoke] [args...]",
  handler: async (args: string, ctx: CommandContext) => {
    const sessionId = ctx.sessionStore.sessionId;
    if (!sessionId) {
      ctx.addSystemMessage(pc.red("No active session."));
      return;
    }

    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0] || "create";
    const rest = parts.slice(1).join(" ");

    switch (subcommand) {
      case "create":
      case "new": {
        const isCollab = rest.includes("--collab");
        const label = rest.replace("--collab", "").trim() || undefined;

        try {
          const { url, share } = await createShare(sessionId, {
            label,
            permission: isCollab ? "collaborate" : "view",
          });

          const permLabel =
            share.permission === "collaborate" ? pc.yellow("collaborate") : pc.green("view-only");

          ctx.addSystemMessage(
            `${pc.green("✔")} Share link created (${permLabel})\n` +
              `  ${pc.bold(url)}\n` +
              pc.dim(
                `  Expires: ${share.expires_at ? new Date(share.expires_at).toLocaleString() : "never"}`,
              ),
          );
        } catch (error) {
          const msg = extractErrorMessage(error);
          ctx.addSystemMessage(pc.red(`Failed to create share: ${msg}`));
        }
        break;
      }

      case "list":
      case "ls": {
        try {
          const { shares } = await listShares(sessionId);

          if (shares.length === 0) {
            ctx.addSystemMessage(pc.dim("No active share links for this session."));
            return;
          }

          const header = pc.bold(`Share links (${shares.length})`);
          const lines = shares.map(formatShare);
          ctx.addSystemMessage(`${header}\n${lines.join("\n")}`);
        } catch (error) {
          const msg = extractErrorMessage(error);
          ctx.addSystemMessage(pc.red(`Failed to list shares: ${msg}`));
        }
        break;
      }

      case "revoke": {
        if (!rest) {
          ctx.addSystemMessage(pc.red("Usage: /share revoke <share-id>"));
          return;
        }

        try {
          // Support short IDs by matching against the list
          const { shares } = await listShares(sessionId);
          const match = shares.find((s) => s.id === rest || s.id.startsWith(rest));

          if (!match) {
            ctx.addSystemMessage(pc.red(`Share ${rest} not found.`));
            return;
          }

          await revokeShare(match.id);
          ctx.addSystemMessage(`${pc.green("✔")} Revoked share ${pc.dim(match.id.slice(0, 8))}`);
        } catch (error) {
          const msg = extractErrorMessage(error);
          ctx.addSystemMessage(pc.red(`Failed to revoke share: ${msg}`));
        }
        break;
      }

      default:
        ctx.addSystemMessage(
          pc.dim(
            "Usage: /share [create|list|revoke]\n" +
              "  create [label] [--collab]  Create a share link (default: view-only)\n" +
              "  list                       List active share links\n" +
              "  revoke <id>                Revoke a share link",
          ),
        );
    }
  },
});
