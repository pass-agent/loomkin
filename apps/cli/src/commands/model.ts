import * as p from "@clack/prompts";
import pc from "picocolors";
import { register, type CommandContext } from "./registry.js";
import { listModelProviders } from "../lib/api.js";
import { extractErrorMessage } from "../lib/errors.js";
import type { Model, ModelProvider } from "../lib/types.js";

function isConfigured(provider: ModelProvider): boolean {
  const s = provider.status;
  return (
    (s.type === "api_key" && s.status === "set") ||
    (s.type === "oauth" && s.status === "connected") ||
    (s.type === "local" && s.status === "available")
  );
}

function buildOptions(providers: ModelProvider[]) {
  const options: { value: string; label: string; hint?: string }[] = [];

  for (const provider of providers) {
    if (provider.models.length === 0) continue;

    options.push({
      value: `__separator_${provider.id}`,
      label: pc.dim(`── ${provider.name} ──`),
    });

    for (const model of provider.models) {
      options.push({
        value: model.id,
        label: model.label,
        hint: model.context ? pc.dim(model.context) : undefined,
      });
    }
  }

  return options;
}

function formatProviderStatus(providers: ModelProvider[]): string {
  const configured = providers.filter(isConfigured);
  const unconfigured = providers.filter(
    (p) => !isConfigured(p) && p.status.env_var,
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
  description: "Switch the active model",
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

      const options = buildOptions(providers);
      const currentModel = ctx.appStore.model;

      const selected = await p.select({
        message: `Select a model ${pc.dim(`(current: ${currentModel})`)}`,
        options,
        initialValue: currentModel,
      });

      if (p.isCancel(selected)) {
        ctx.addSystemMessage(pc.dim("Model selection cancelled."));
        return;
      }

      const modelId = selected as string;

      // Ignore separator selections
      if (modelId.startsWith("__separator_")) {
        ctx.addSystemMessage(pc.dim("Model selection cancelled."));
        return;
      }

      const match = allModels.find((m) => m.id === modelId);
      ctx.appStore.setModel(modelId);
      ctx.addSystemMessage(
        `Switched to model ${pc.bold(match?.label ?? modelId)} (${pc.dim(modelId)}).`,
      );
    } catch (error) {
      const msg = extractErrorMessage(error);
      ctx.addSystemMessage(pc.red(`Failed to load models: ${msg}`));
    }
  },
});
