import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { getSessionChannel } from "./channelUtil.js";
import type { KindredBundle } from "../lib/types.js";

register({
  name: "kindred",
  description: "View and manage kindred bundles (kin rosters)",
  args: "[list]",
  handler: async (args: string, ctx: CommandContext) => {
    const channel = getSessionChannel();
    if (!channel) {
      ctx.addSystemMessage(pc.red("No active session."));
      return;
    }

    const parts = args.trim().split(/\s+/);
    const subcommand = parts[0] || "list";

    if (subcommand === "list" || subcommand === "") {
      channel
        .push("list_kindreds", {})
        .receive("ok", (raw: Record<string, unknown>) => {
          const resp = raw as {
            kindreds: KindredBundle[];
            active_id: string | null;
          };

          if (resp.kindreds.length === 0) {
            ctx.addSystemMessage(
              "No kindred bundles found. Create one in the web UI.",
            );
            return;
          }

          const lines = resp.kindreds.map((k) => {
            const isActive = k.id === resp.active_id;
            const marker = isActive ? pc.green("● ") : "  ";
            const name = pc.bold(isActive ? pc.green(k.name) : k.name);
            const version = pc.dim(`v${k.version}`);
            const status =
              k.status === "active"
                ? pc.green(k.status)
                : pc.dim(k.status);
            const count = pc.dim(`${k.item_count} kin`);

            return `${marker}${name} ${version} ${status} ${count}`;
          });

          ctx.addSystemMessage(
            `${pc.bold("Kindred Bundles")}\n${lines.join("\n")}`,
          );
        })
        .receive("error", (raw: Record<string, unknown>) => {
          const resp = raw as { reason: string };
          ctx.addSystemMessage(pc.red(`Failed: ${resp.reason}`));
        });
      return;
    }

    ctx.addSystemMessage(`Usage: /kindred [list]`);
  },
});
