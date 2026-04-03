import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { useAgentStore } from "../stores/agentStore.js";
import { getSessionChannel } from "./channelUtil.js";
import type { KinAgent } from "../lib/types.js";

register({
  name: "kin",
  description: "Browse and spawn from your kin library",
  args: "[list | spawn <name> | info <name>]",
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
        .push("list_kin", {})
        .receive("ok", (raw: Record<string, unknown>) => {
          const resp = raw as { kin: KinAgent[] };
          if (resp.kin.length === 0) {
            ctx.addSystemMessage(
              "No kin configured. Create kin in the web UI or database.",
            );
            return;
          }

          const lines = resp.kin.map((k) => {
            const name = pc.bold(pc.cyan(k.name));
            const role = pc.dim(`(${k.role})`);
            const potency = pc.yellow(`P${k.potency}`);
            const auto = k.auto_spawn ? pc.green(" auto") : "";
            const model = k.model_override
              ? pc.dim(` model:${k.model_override}`)
              : "";
            const display = k.display_name
              ? ` ${pc.dim(k.display_name)}`
              : "";
            const tags =
              k.tags.length > 0 ? pc.dim(` [${k.tags.join(", ")}]`) : "";

            return `  ${potency} ${name} ${role}${display}${auto}${model}${tags}`;
          });

          ctx.addSystemMessage(
            `${pc.bold("Kin Library")} (${resp.kin.length} agents)\n${lines.join("\n")}`,
          );
        })
        .receive("error", (raw: Record<string, unknown>) => {
          const resp = raw as { reason: string };
          ctx.addSystemMessage(pc.red(`Failed: ${resp.reason}`));
        });
      return;
    }

    if (subcommand === "spawn") {
      const kinName = parts[1];
      if (!kinName) {
        ctx.addSystemMessage(pc.red("Usage: /kin spawn <name>"));
        return;
      }

      ctx.addSystemMessage(pc.dim(`Spawning kin "${kinName}"...`));

      channel
        .push("spawn_kin", { name: kinName })
        .receive("ok", (raw: Record<string, unknown>) => {
          const resp = raw as {
            name: string;
            role: string;
            team_id: string;
            display_name: string | null;
          };
          useAgentStore.getState().upsertAgent(resp.name, {
            role: resp.role,
            teamId: resp.team_id,
            status: "idle",
          });

          const label = resp.display_name || resp.name;
          ctx.addSystemMessage(
            `${pc.green("✔")} Spawned kin ${pc.bold(label)} (${pc.cyan(resp.role)}) — concierge notified`,
          );
        })
        .receive("error", (raw: Record<string, unknown>) => {
          const resp = raw as { reason: string };
          ctx.addSystemMessage(pc.red(`Failed to spawn kin: ${resp.reason}`));
        });
      return;
    }

    if (subcommand === "info") {
      const kinName = parts[1];
      if (!kinName) {
        ctx.addSystemMessage(pc.red("Usage: /kin info <name>"));
        return;
      }

      channel
        .push("list_kin", {})
        .receive("ok", (raw: Record<string, unknown>) => {
          const resp = raw as { kin: KinAgent[] };
          const kin = resp.kin.find(
            (k) => k.name.toLowerCase() === kinName.toLowerCase(),
          );
          if (!kin) {
            ctx.addSystemMessage(pc.red(`Kin "${kinName}" not found.`));
            return;
          }

          const lines = [
            `${pc.bold(pc.cyan(kin.name))}${kin.display_name ? ` (${kin.display_name})` : ""}`,
            `  Role: ${pc.cyan(kin.role)}`,
            `  Potency: ${pc.yellow(String(kin.potency))}`,
            `  Auto-spawn: ${kin.auto_spawn ? pc.green("yes") : "no"}`,
          ];

          if (kin.model_override)
            lines.push(`  Model: ${kin.model_override}`);
          if (kin.budget_limit)
            lines.push(`  Budget: $${kin.budget_limit}`);
          if (kin.spawn_context)
            lines.push(`  Spawn context: ${kin.spawn_context}`);
          if (kin.tags.length > 0)
            lines.push(`  Tags: ${kin.tags.join(", ")}`);
          if (kin.system_prompt_extra)
            lines.push(
              `  Extra prompt: ${pc.dim(kin.system_prompt_extra.slice(0, 120))}${kin.system_prompt_extra.length > 120 ? "..." : ""}`,
            );

          ctx.addSystemMessage(lines.join("\n"));
        })
        .receive("error", (raw: Record<string, unknown>) => {
          const resp = raw as { reason: string };
          ctx.addSystemMessage(pc.red(`Failed: ${resp.reason}`));
        });
      return;
    }

    ctx.addSystemMessage(
      `Usage: /kin [list | spawn <name> | info <name>]`,
    );
  },
});
