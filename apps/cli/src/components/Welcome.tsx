import * as p from "@clack/prompts";
import pc from "picocolors";
import { setConfig } from "../lib/config.js";
import { login, register, anonymousLogin, ApiError, listModelProviders } from "../lib/api.js";
import { DEFAULT_SERVER_URL } from "../lib/constants.js";
import { themeList, getTheme } from "../lib/themes.js";
import { useThemeStore } from "../stores/themeStore.js";
import type { AuthResponse } from "../lib/types.js";
import { runOAuthFlow } from "../lib/oauth.js";
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

type FlowResult = AuthResponse | "switch_to_register" | "switch_to_login" | false;

async function runLoginFlow(): Promise<FlowResult> {
  const email = await p.text({
    message: "Email",
    validate: (value) => {
      if (!value || !value.includes("@")) return "Valid email required";
    },
  });

  if (p.isCancel(email)) return false;

  const password = await p.password({
    message: "Password",
    validate: (value) => {
      if (!value || value.length < 12) return "Password must be at least 12 characters";
    },
  });

  if (p.isCancel(password)) return false;

  const spinner = p.spinner();
  spinner.start("Logging in...");

  try {
    const response = await login({
      email: email as string,
      password: password as string,
    });
    spinner.stop("Logged in!");
    return response;
  } catch (err) {
    spinner.stop("Login failed.");

    if (err instanceof ApiError && err.status === 401) {
      const recovery = await p.select({
        message: "Invalid email or password. What would you like to do?",
        options: [
          { value: "retry", label: "Try again" },
          { value: "register", label: "Create account" },
          { value: "guest", label: "Continue as guest" },
          { value: "exit", label: "Exit" },
        ],
      });

      if (p.isCancel(recovery) || recovery === "exit") return false;
      if (recovery === "register") return "switch_to_register";
      if (recovery === "guest") return runAnonymousFlow();
      // retry — recurse
      return runLoginFlow();
    }

    p.log.error(err instanceof Error ? err.message : "Unknown error occurred");
    return false;
  }
}

async function runRegisterFlow(): Promise<FlowResult> {
  const email = await p.text({
    message: "Email",
    validate: (value) => {
      if (!value || !value.includes("@")) return "Valid email required";
    },
  });

  if (p.isCancel(email)) return false;

  const password = await p.password({
    message: "Password",
    validate: (value) => {
      if (!value || value.length < 12) return "Password must be at least 12 characters";
    },
  });

  if (p.isCancel(password)) return false;

  const confirmPassword = await p.password({
    message: "Confirm password",
    validate: (value) => {
      if (value !== (password as string)) return "Passwords do not match";
    },
  });

  if (p.isCancel(confirmPassword)) return false;

  const spinner = p.spinner();
  spinner.start("Creating account...");

  try {
    const response = await register({
      email: email as string,
      password: password as string,
    });
    spinner.stop("Account created!");
    return response;
  } catch (err) {
    spinner.stop("Registration failed.");

    if (err instanceof ApiError && err.status === 422) {
      const parsed = err.parsedBody;
      const errors = parsed?.errors;

      if (errors?.email?.some((e: string) => e.includes("already been taken"))) {
        const recovery = await p.select({
          message: "That email is already registered. What would you like to do?",
          options: [
            { value: "login", label: "Log in instead" },
            { value: "retry", label: "Try a different email" },
            { value: "exit", label: "Exit" },
          ],
        });

        if (p.isCancel(recovery) || recovery === "exit") return false;
        if (recovery === "login") return "switch_to_login";
        return runRegisterFlow();
      }

      // Show other validation errors
      const message = parsed?.message || formatErrors(errors);
      p.log.error(message || "Validation error");
    } else {
      p.log.error(err instanceof Error ? err.message : "Unknown error occurred");
    }

    return false;
  }
}

async function runAnonymousFlow(): Promise<FlowResult> {
  const spinner = p.spinner();
  spinner.start("Setting up guest access...");

  try {
    const response = await anonymousLogin();
    spinner.stop("Guest access ready!");
    return response;
  } catch (err) {
    spinner.stop("Guest access failed.");
    p.log.error(err instanceof Error ? err.message : "Unknown error occurred");

    const recovery = await p.select({
      message: "What would you like to do?",
      options: [
        { value: "register", label: "Try creating an account" },
        { value: "exit", label: "Exit" },
      ],
    });

    if (p.isCancel(recovery) || recovery === "exit") return false;
    if (recovery === "register") return "switch_to_register";
    return false;
  }
}

function formatErrors(errors?: Record<string, string[]>): string {
  if (!errors) return "";
  return Object.entries(errors)
    .map(([field, msgs]) => `${field}: ${msgs.join(", ")}`)
    .join("; ");
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

    if (p.isCancel(selected) || selected === "__skip" || (selected as string).startsWith("__sep_")) {
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

  let flow: "login" | "register" | "guest" | null = null;

  const choice = await p.select({
    message: "How would you like to get started?",
    options: [
      { value: "login", label: "Log in", hint: "I have an account" },
      { value: "register", label: "Create account", hint: "I'm new here" },
      { value: "guest", label: "Continue as guest", hint: "No account needed" },
    ],
  });

  if (p.isCancel(choice)) {
    p.cancel("Setup cancelled.");
    return false;
  }

  flow = choice as "login" | "register" | "guest";

  // Loop to allow switching between flows on error recovery
  while (flow) {
    let result: FlowResult;

    if (flow === "login") {
      result = await runLoginFlow();
    } else if (flow === "register") {
      result = await runRegisterFlow();
    } else {
      result = await runAnonymousFlow();
    }

    if (result === "switch_to_register") {
      flow = "register";
      continue;
    }

    if (result === "switch_to_login") {
      flow = "login";
      continue;
    }

    if (result === false) {
      p.outro(pc.red("Setup failed. Please try again."));
      return false;
    }

    // Success — save token and proceed
    setConfig({ token: result.token });

    await selectModel();

    await selectTheme();

    const connectProvider = await p.confirm({
      message: "Would you like to connect an OAuth provider now? (Anthropic, Google, or OpenAI)",
      initialValue: false,
    });

    if (!p.isCancel(connectProvider) && connectProvider) {
      const choice = await p.select({
        message: "Which provider?",
        options: [
          { value: "anthropic", label: "Anthropic", hint: "Claude models via OAuth" },
          { value: "google", label: "Google", hint: "Gemini models via OAuth" },
          { value: "openai", label: "OpenAI", hint: "GPT/Codex models via OAuth" },
          { value: "skip", label: "Skip for now", hint: "Connect later with /provider" },
        ],
      });

      if (!p.isCancel(choice) && choice !== "skip") {
        const providerNames: Record<string, string> = {
          anthropic: "Anthropic",
          google: "Google",
          openai: "OpenAI",
        };
        await runOAuthFlow(choice as string, providerNames[choice as string]);
      }
    }

    p.outro(pc.green("You're all set! Launching Loomkin TUI..."));
    return true;
  }

  return false;
}
