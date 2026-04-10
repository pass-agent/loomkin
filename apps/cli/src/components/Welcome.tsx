import * as p from "@clack/prompts";
import pc from "picocolors";
import { setConfig } from "../lib/config.js";
import { anonymousLogin, bootstrapWithCloudToken, listModelProviders } from "../lib/api.js";
import { DEFAULT_SERVER_URL } from "../lib/constants.js";
import { themeList, getTheme } from "../lib/themes.js";
import { useThemeStore } from "../stores/themeStore.js";
import { runDeviceCodeFlow } from "../lib/deviceCodeFlow.js";
import { getCloudToken } from "../lib/cloudConfig.js";
import { isProviderConfigured } from "../lib/modelUtils.js";
import { useAppStore } from "../stores/appStore.js";

async function selectTheme(): Promise<void> {
  const themeChoice = await p.select({
    message: "Choose a color theme",
    options: themeList.map((t) => {
      const cb = t.colorblind ? " [colorblind-friendly]" : "";
      const swatch = `${t.success("✔")} ${t.error("✖")} ${t.warning("⚠")} ${t.info("ℹ")} ${t.agentWorking("●")} ${t.agentIdle("○")}`;
      return {
        value: t.name,
        label: `${t.label}${cb}`,
        hint: `${swatch}  ${t.dim(t.description)}`,
      };
    }),
    initialValue: "loomkin",
  });

  if (!p.isCancel(themeChoice)) {
    const chosen = themeChoice as string;
    useThemeStore.getState().setTheme(chosen);
    const t = getTheme(chosen);
    p.log.success(`Theme set to ${t.bold(t.label)}`);
    p.log.info(pc.dim("You can change this anytime with /theme"));
  }
}

async function runCloudAuthFlow(): Promise<boolean> {
  const messages: string[] = [];
  const success = await runDeviceCodeFlow((msg) => {
    messages.push(msg);
    p.log.message(msg);
  });

  if (!success) return false;

  // Get the cloud token that was just stored by runDeviceCodeFlow
  const cloudToken = getCloudToken();
  if (!cloudToken) {
    p.log.error("Cloud authentication succeeded but no token was stored.");
    return false;
  }

  // Bootstrap a local user from the cloud identity
  const spinner = p.spinner();
  spinner.start("Setting up local account...");

  try {
    const response = await bootstrapWithCloudToken(cloudToken);
    spinner.stop("Local account ready!");
    setConfig({ token: response.token });
    return true;
  } catch (err) {
    spinner.stop("Local setup failed.");
    p.log.error(err instanceof Error ? err.message : "Failed to bootstrap local account");
    return false;
  }
}

async function runAnonymousFlow(): Promise<boolean> {
  const spinner = p.spinner();
  spinner.start("Setting up guest access...");

  try {
    const response = await anonymousLogin();
    spinner.stop("Guest access ready!");
    setConfig({ token: response.token });
    return true;
  } catch (err) {
    spinner.stop("Guest access failed.");
    p.log.error(err instanceof Error ? err.message : "Unknown error occurred");
    return false;
  }
}

async function selectModel(): Promise<void> {
  const spinner = p.spinner();
  spinner.start("Checking available providers...");

  let providers;
  try {
    const result = await listModelProviders();
    providers = result.providers;
    spinner.stop("Providers loaded.");
  } catch {
    spinner.stop("");
    p.log.warn("Could not load providers — you can configure a model later with /model");
    return;
  }

  const configured = providers.filter(isProviderConfigured);

  if (configured.length > 0) {
    // Build model options from configured providers
    const options: { value: string; label: string; hint?: string }[] = [];
    for (const provider of configured) {
      if (provider.models.length === 0) continue;
      options.push({
        value: `__sep_${provider.id}`,
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
    options.push({ value: "__skip", label: pc.dim("Skip for now") });

    const selected = await p.select({
      message: "Select a default model",
      options,
    });

    if (
      p.isCancel(selected) ||
      selected === "__skip" ||
      (selected as string).startsWith("__sep_")
    ) {
      p.log.info(pc.dim("You can configure a model anytime with /model"));
      return;
    }

    const modelId = selected as string;
    setConfig({ defaultModel: modelId });
    useAppStore.getState().setModel(modelId);
    p.log.success(`Default model set to ${pc.bold(modelId.replace(/^[^:]+:/, ""))}`);
  } else {
    // No providers configured — show env var guidance
    const lines = [
      pc.yellow("No model providers are configured yet."),
      pc.dim("To configure a provider, set the appropriate environment variable on the server:"),
      "",
    ];
    const envVars: Record<string, string> = {
      Anthropic: "ANTHROPIC_API_KEY",
      OpenAI: "OPENAI_API_KEY",
      Google: "GOOGLE_API_KEY",
      Groq: "GROQ_API_KEY",
      "x.AI": "XAI_API_KEY",
    };
    for (const [name, envVar] of Object.entries(envVars)) {
      lines.push(`  ${name.padEnd(12)} → ${pc.cyan(envVar)}`);
    }
    p.log.message(lines.join("\n"));
    p.log.info(pc.dim("You can also connect via OAuth with /provider after launching."));
  }
}

export async function runSetupWizard(): Promise<boolean> {
  p.intro(pc.bold("Welcome to Loomkin CLI"));

  const serverUrl = await p.text({
    message: "Server URL",
    placeholder: DEFAULT_SERVER_URL,
    defaultValue: DEFAULT_SERVER_URL,
    validate: (value) => {
      const url = value || DEFAULT_SERVER_URL;
      try {
        new URL(url);
      } catch {
        return "Invalid URL";
      }
    },
  });

  if (p.isCancel(serverUrl)) {
    p.cancel("Setup cancelled.");
    return false;
  }

  setConfig({ serverUrl: serverUrl as string });

  const choice = await p.select({
    message: "How would you like to get started?",
    options: [
      {
        value: "cloud",
        label: "Connect your Loomkin account",
        hint: "opens browser for sign-in at loomkin.dev",
      },
      { value: "guest", label: "Continue as guest", hint: "no account needed, limited features" },
    ],
  });

  if (p.isCancel(choice)) {
    p.cancel("Setup cancelled.");
    return false;
  }

  let authenticated = false;

  if (choice === "cloud") {
    authenticated = await runCloudAuthFlow();

    // If cloud auth failed (e.g. loomkin.dev unreachable), offer fallback
    if (!authenticated) {
      const fallback = await p.select({
        message: "Cloud authentication failed. What would you like to do?",
        options: [
          { value: "retry", label: "Try again" },
          { value: "guest", label: "Continue as guest" },
          { value: "exit", label: "Exit" },
        ],
      });

      if (p.isCancel(fallback) || fallback === "exit") {
        p.cancel("Setup cancelled.");
        return false;
      }

      if (fallback === "retry") {
        authenticated = await runCloudAuthFlow();
      } else {
        authenticated = await runAnonymousFlow();
      }
    }
  } else {
    authenticated = await runAnonymousFlow();
  }

  if (!authenticated) {
    p.outro(pc.red("Setup failed. Please try again."));
    return false;
  }

  await selectModel();

  await selectTheme();

  p.outro(pc.green("You're all set! Launching Loomkin TUI..."));
  return true;
}
