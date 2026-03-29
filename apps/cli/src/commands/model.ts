import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { listModelProviders } from "../lib/api.js";
import { extractErrorMessage } from "../lib/errors.js";
import { isProviderConfigured } from "../lib/modelUtils.js";
import type { ModelProvider } from "../lib/types.js";


function formatProviderStatus(providers: ModelProvider[]): string {
  const configured = providers.filter(isProviderConfigured);
  const unconfigured = providers.filter(
    (p) => !isProviderConfigured(p) && p.status.env_var,
  );

  const lines: string[] = [];

  if (configured.length > 0) {
    lines.push(pc.bold("Configured providers:"));
    for (const p of configured) {
      lines.push(`  ${pc.green("✔")} ${p.name} (${p.models.length} models)`);
    }
  }

  if (unconfigured.length > 0) {
    if (lines.length > 0) lines.push("");
    lines.push(pc.bold("Unconfigured providers:"));
    for (const p of unconfigured) {
      lines.push(`  ${pc.dim("○")} ${p.name} — set ${pc.cyan(p.status.env_var!)}`);
    }
  }

  return lines.join("\n");
}

register({
  name: "model",
  description: "Browse and switch models (e.g. /model google:gemini-2.5-pro)",
  args: "[model-id]",
  handler: async (args: string, ctx: CommandContext) => {
    const requested = args.trim();

    // Direct model ID provided — validate and set
    if (requested) {
      try {
        const { providers } = await listModelProviders();
        const allModels = providers.flatMap((prov) => prov.models);
        const match = allModels.find((m) => m.id === requested);

        if (!match) {
          // Could be a valid provider:model string not in the catalog
          if (requested.includes(":")) {
            ctx.appStore.setModel(requested);
            ctx.setSessionModel?.(requested);
            ctx.addSystemMessage(
              `Switched to model ${pc.bold(requested)}. ${pc.dim("(not in catalog — verify the ID is correct)")}`,
            );
            return;
          }

          const lines = [`Unknown model ${pc.red(requested)}.`];
          if (allModels.length > 0) {
            lines.push(`Run ${pc.cyan("/model")} to browse available models.`);
          } else {
            lines.push("");
            lines.push(formatProviderStatus(providers));
          }
          ctx.addSystemMessage(lines.join("\n"));
          return;
        }

        ctx.appStore.setModel(match.id);
        ctx.setSessionModel?.(match.id);
        ctx.addSystemMessage(`Switched to model ${pc.bold(match.label)} (${pc.dim(match.id)}).`);
      } catch (error) {
        const msg = extractErrorMessage(error);
        ctx.addSystemMessage(pc.red(`Failed to validate model: ${msg}`));
      }
      return;
    }

    // No args — interactive selection
    try {
      const { providers } = await listModelProviders();
      const allModels = providers.flatMap((prov) => prov.models);

      if (allModels.length === 0) {
        const lines = [
          pc.yellow("No models available — no providers are configured."),
          "",
          formatProviderStatus(providers),
          "",
          pc.dim(`Or set a model directly: /model provider:model-id`),
        ];
        ctx.addSystemMessage(lines.join("\n"));
        return;
      }

      if (ctx.showModelPicker) {
        ctx.showModelPicker(providers);
        return;
      }

      // Fallback for non-interactive contexts (tests, piped input)
      ctx.addSystemMessage(
        [
          pc.bold("Available models:"),
          ...providers.flatMap((prov) =>
            prov.models.map((m) => `  ${pc.cyan(m.id)}  ${pc.dim(m.label)}`),
          ),
          "",
          pc.dim("Use /model <id> to switch."),
        ].join("\n"),
      );
    } catch (error) {
      const msg = extractErrorMessage(error);
      ctx.addSystemMessage(pc.red(`Failed to load models: ${msg}`));
    }
  },
});
