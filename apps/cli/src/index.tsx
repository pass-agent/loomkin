#!/usr/bin/env bun
import React from "react";
import { render } from "ink";
import meow from "meow";
import pc from "picocolors";
import { appendFileSync, openSync, readFileSync } from "fs";
import { App } from "./app.js";
import { ErrorBoundary } from "./components/ErrorBoundary.js";
import {
  isAuthenticated,
  setConfig,
  getLastSessionId,
  setLastSessionId,
} from "./lib/config.js";
import { runSetupWizard } from "./components/Welcome.js";
import { useAppStore } from "./stores/appStore.js";
import { useSessionStore } from "./stores/sessionStore.js";
import {
  createSession,
  getSession,
  getSessionMessages,
  sendMessageRest,
  listModelProviders,
  ApiError,
} from "./lib/api.js";
import { getApiBaseUrl } from "./lib/urls.js";
import { DEV_FALLBACK_URL } from "./lib/constants.js";
import { isProviderConfigured } from "./lib/modelUtils.js";
import { runPrintMode } from "./lib/print.js";

const cli = meow(
  `
  Usage
    $ loomkin [options]
    $ loomkin -p "your prompt"
    $ echo "fix the bug" | loomkin -p -

  Options
    --server, -s                    Server URL (env: LOOMKIN_SERVER_URL)
    --model, -m                     Model to use (default: first configured provider)
    --mode                          Interaction mode: code, plan, chat (default: code)
    --session                       Resume a specific session by ID
    --new, -n                       Force a new session (ignore last session)
    --resume, -r                    Resume the most recent session (explicit)
    --continue                      Resume the most recent session (shorthand)
    --print, -p                     Non-interactive: send prompt, print response, exit
    --output-format                 Output format for --print: text, json, or stream-json (default: text)
    --prompt-file                   Read initial prompt from file instead of argument
    --cwd, -c                       Override working directory
    --verbose, -v                   Verbose logging (socket events, API calls)
    --debug                         Show full error stack traces and state changes
    --quiet, -q                     Suppress spinners and status bar output
    --no-color                      Suppress ANSI color output (also respects NO_COLOR env var)
    --log-file                      Redirect debug/verbose output to file instead of stderr
    --api-key                       Override stored API key for this invocation
    --system-prompt                 Prepend a custom system prompt to the session
    --dangerously-skip-permissions  Auto-approve all tool calls (no prompts)
    --allowed-tools                 Comma-separated allowlist of tool names
    --disallowed-tools              Comma-separated denylist of tool names
    --max-turns                     Limit agent turns before stopping
    --timeout                       Max execution time in ms for --print mode
    --tool-timeout                  Per-tool execution timeout in ms
    --dry-run                       Parse and validate without executing
    --cost-limit                    Maximum spend in USD; stop if exceeded

  Examples
    $ loomkin
    $ loomkin --mode plan
    $ loomkin --session abc123
    $ loomkin -p "what is 2+2"
    $ loomkin -p "list files" --output-format json
    $ loomkin -p "summarize" --output-format stream-json
    $ loomkin --cwd /path/to/project
    $ loomkin --dangerously-skip-permissions -p "refactor auth"
    $ loomkin --no-color -p "generate report" | tee report.txt
    $ loomkin -p "deploy" --timeout 30000 --cost-limit 0.50
    $ loomkin --prompt-file ./prompt.txt -p -
`,
  {
    importMeta: import.meta,
    flags: {
      // Existing
      server: { type: "string", shortFlag: "s" },
      model: { type: "string", shortFlag: "m" },
      mode: { type: "string" },
      session: { type: "string" },
      new: { type: "boolean", shortFlag: "n", default: false },
      // Tier 1 — Automation
      print: { type: "string", shortFlag: "p" },
      outputFormat: { type: "string", default: "text" },
      cwd: { type: "string", shortFlag: "c" },
      verbose: { type: "boolean", shortFlag: "v", default: false },
      // Tier 2 — Safety
      dangerouslySkipPermissions: { type: "boolean", default: false },
      allowedTools: { type: "string" },
      disallowedTools: { type: "string" },
      maxTurns: { type: "number" },
      // Tier 3 — Configuration
      systemPrompt: { type: "string" },
      resume: { type: "boolean", shortFlag: "r", default: false },
      debug: { type: "boolean", default: false },
      // Tier 4 — CI/CD & Automation
      noColor: { type: "boolean", default: false },
      quiet: { type: "boolean", shortFlag: "q", default: false },
      timeout: { type: "number" },
      logFile: { type: "string" },
      apiKey: { type: "string" },
      promptFile: { type: "string" },
      continue: { type: "boolean", default: false },
      toolTimeout: { type: "number" },
      dryRun: { type: "boolean", default: false },
      costLimit: { type: "number" },
    },
  },
);

// Capture keystrokes typed before Ink renders and store them for InputArea to replay.
// Must be called before render() to avoid losing early input.
function seedEarlyInput(): () => void {
  const chunks: string[] = [];

  function onData(data: Buffer) {
    const s = data.toString("utf-8");
    // Only capture printable characters — ignore control sequences (ESC, etc.)
    const printable = s.replace(/[\x00-\x1f\x7f]/g, "");
    if (printable) chunks.push(printable);
  }

  if (process.stdin.isTTY) {
    process.stdin.setRawMode?.(true);
    process.stdin.on("data", onData);
  }

  return () => {
    if (process.stdin.isTTY) {
      process.stdin.off("data", onData);
      process.stdin.setRawMode?.(false);
    }
    const captured = chunks.join("");
    if (captured) {
      useAppStore.getState().setEarlyInput(captured);
    }
  };
}

// Startup phase timer for --debug mode
class StartupTimer {
  private marks = new Map<string, number>();
  private start = performance.now();

  mark(phase: string): void {
    this.marks.set(phase, performance.now() - this.start);
  }

  dump(): void {
    const entries = Array.from(this.marks.entries())
      .map(([phase, ms]) => `${phase}: ${ms.toFixed(0)}ms`)
      .join(", ");
    console.error(pc.dim(`[startup] ${entries}`));
  }
}

async function detectServerUrl(): Promise<void> {
  if (!DEV_FALLBACK_URL) return;
  if (cli.flags.server || process.env.LOOMKIN_SERVER_URL) return;

  const url = getApiBaseUrl();
  if (url === DEV_FALLBACK_URL) return;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 2000);
    await fetch(`${url}/api/v1`, { method: "HEAD", signal: controller.signal });
    clearTimeout(timer);
  } catch {
    console.error(pc.yellow(`Cannot reach ${url}, falling back to ${DEV_FALLBACK_URL}`));
    process.env.LOOMKIN_SERVER_URL = DEV_FALLBACK_URL;
  }
}

async function resumeSession(sessionId: string): Promise<boolean> {
  console.error(pc.dim(`Resuming session ${sessionId.slice(0, 8)}…`));

  try {
    const { session } = await getSession(sessionId);
    useSessionStore.getState().setSessionId(sessionId);

    // Sync server-persisted model before the React app renders
    if (session.model) {
      useAppStore.getState().setModel(session.model);
    }

    const { messages } = await getSessionMessages(sessionId);
    if (messages.length > 0) {
      useSessionStore.getState().loadMessages(messages);
    }
    setLastSessionId(sessionId);
    console.error(pc.green(`Resumed session ${sessionId.slice(0, 8)} (${messages.length} messages)`));
    return true;
  } catch {
    console.error(pc.yellow(`Could not resume session ${sessionId.slice(0, 8)}, creating new…`));
    setLastSessionId(null);
    return false;
  }
}

async function createNewSession(): Promise<string> {
  console.error(pc.dim("Creating session…"));

  try {
    const { session } = await createSession({
      model: useAppStore.getState().model,
      project_path: process.cwd(),
    });
    useSessionStore.getState().setSessionId(session.id);
    setLastSessionId(session.id);
    console.error(pc.green(`Session ${session.id.slice(0, 8)} ready`));
    return session.id;
  } catch (err) {
    console.error(pc.red("Failed to create session"));
    throw err;
  }
}

async function resolveSessionId(): Promise<string | null> {
  const sessionFlag = cli.flags.session;
  const lastSession = getLastSessionId();

  if (cli.flags.new) {
    return createNewSession();
  }

  if (sessionFlag) {
    const resumed = await resumeSession(sessionFlag);
    if (resumed) return sessionFlag;
    return createNewSession();
  }

  if (cli.flags.resume || cli.flags.continue || lastSession) {
    const target = lastSession;
    if (target) {
      const resumed = await resumeSession(target);
      if (resumed) return target;
    }
    return createNewSession();
  }

  return createNewSession();
}

async function main() {
  // Apply --cwd before anything else
  if (cli.flags.cwd) {
    process.chdir(cli.flags.cwd);
  }

  // Apply CLI flags to config/store
  if (cli.flags.server) {
    setConfig({ serverUrl: cli.flags.server });
  }
  if (cli.flags.model) {
    useAppStore.getState().setModel(cli.flags.model);
  }
  if (cli.flags.mode) {
    const mode = cli.flags.mode as "code" | "plan" | "chat";
    useAppStore.getState().setMode(mode);
  }

  // Apply new flags to store
  const store = useAppStore.getState();
  if (cli.flags.verbose) store.setVerbose(true);
  if (cli.flags.debug) store.setDebug(true);
  if (cli.flags.dangerouslySkipPermissions) store.setSkipPermissions(true);
  if (cli.flags.allowedTools) {
    store.setAllowedTools(cli.flags.allowedTools.split(",").map((t) => t.trim()));
  }
  if (cli.flags.disallowedTools) {
    store.setDisallowedTools(cli.flags.disallowedTools.split(",").map((t) => t.trim()));
  }
  if (cli.flags.maxTurns != null) {
    store.setMaxTurns(cli.flags.maxTurns);
  }

  // Apply automation/CI flags to store
  if (cli.flags.noColor || process.env.NO_COLOR) {
    // picocolors already reads NO_COLOR env; set env var so all instances respect it
    process.env.NO_COLOR = "1";
    store.setNoColor(true);
  }
  if (cli.flags.quiet) store.setQuiet(true);
  if (cli.flags.timeout != null) store.setTimeout(cli.flags.timeout);
  if (cli.flags.toolTimeout != null) store.setToolTimeout(cli.flags.toolTimeout);
  if (cli.flags.dryRun) store.setDryRun(true);
  if (cli.flags.costLimit != null) store.setCostLimit(cli.flags.costLimit);
  if (cli.flags.logFile) {
    store.setLogFile(cli.flags.logFile);
    // Open (create/truncate) the log file synchronously so we can append to it
    // via a fast synchronous write — avoids async flush complexity in console.error.
    openSync(cli.flags.logFile, "w"); // create/truncate
    console.error = (...args: unknown[]) => {
      const line = args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ");
      appendFileSync(cli.flags.logFile as string, line + "\n");
    };
  }
  if (cli.flags.promptFile) {
    store.setPromptFile(cli.flags.promptFile);
  }
  if (cli.flags.continue) {
    store.setContinueSession(true);
  }
  if (cli.flags.apiKey) {
    // Override the stored token for this invocation only (not persisted)
    store.setToken(cli.flags.apiKey);
  }

  const timer = new StartupTimer();

  // Parallelize: server detection can run concurrently with local config reads.
  // isAuthenticated() is a synchronous config read — resolve it immediately while
  // detectServerUrl() does its network HEAD request.
  const [, alreadyAuthed] = await Promise.all([
    detectServerUrl().then(() => timer.mark("server-detect")),
    Promise.resolve(isAuthenticated()),
  ]);

  timer.mark("config-read");

  // Check auth — run setup wizard if needed (requires URL to be set, so after detectServerUrl)
  if (!alreadyAuthed) {
    const success = await runSetupWizard();
    if (!success) {
      process.exit(1);
    }
    // Reload token into store
    const { getConfig } = await import("./lib/config.js");
    useAppStore.getState().setToken(getConfig().token);
    timer.mark("auth-wizard");
  }

  // Non-interactive print mode: skip early input buffering (stdin used for prompt)
  if (cli.flags.print != null) {
    let prompt = cli.flags.print;

    // --prompt-file: read prompt from file (overrides argument)
    if (cli.flags.promptFile) {
      try {
        prompt = readFileSync(cli.flags.promptFile, "utf-8").trim();
      } catch (err) {
        console.error(`Error: could not read --prompt-file "${cli.flags.promptFile}": ${err instanceof Error ? err.message : String(err)}`);
        process.exit(1);
      }
    } else if (prompt === "-") {
      // Read from stdin if "-" is passed
      const chunks: Buffer[] = [];
      for await (const chunk of process.stdin) {
        chunks.push(chunk as Buffer);
      }
      prompt = Buffer.concat(chunks).toString("utf-8").trim();
    }

    if (!prompt) {
      console.error("Error: --print requires a prompt or piped input with -p -");
      process.exit(1);
    }

    // --dry-run: parse and validate without executing
    if (cli.flags.dryRun) {
      process.stdout.write(JSON.stringify({ dry_run: true, prompt, flags: cli.flags }) + "\n");
      process.exit(0);
    }

    // --timeout: kill if print mode hangs
    let timeoutHandle: ReturnType<typeof setTimeout> | null = null;
    if (cli.flags.timeout != null) {
      timeoutHandle = setTimeout(() => {
        console.error(`Error: timed out after ${cli.flags.timeout}ms`);
        process.exit(1);
      }, cli.flags.timeout);
    }

    try {
      const sessionId = await resolveSessionId();

      // Send system prompt first if provided
      if (cli.flags.systemPrompt && sessionId) {
        await sendMessageRest(sessionId, cli.flags.systemPrompt);
      }

      await runPrintMode({
        prompt,
        outputFormat: cli.flags.outputFormat as "text" | "json" | "stream-json",
        sessionId: sessionId ?? undefined,
      });
    } catch (err) {
      if (useAppStore.getState().debug && err instanceof Error) {
        console.error(err.stack);
      } else {
        console.error(
          `Error: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
      process.exit(1);
    } finally {
      if (timeoutHandle != null) clearTimeout(timeoutHandle);
    }
    process.exit(0);
  }

  // Start buffering early stdin before the TUI renders, so keystrokes
  // typed during session setup are not lost.
  const stopEarlyInput = seedEarlyInput();

  // Interactive mode — create or resume session
  try {
    await resolveSessionId();
    timer.mark("session-resolve");
    // Only show model picker if no model is already set (e.g. from a resumed session or --model flag)
    if (!useAppStore.getState().model) {
      useAppStore.getState().setShowModelPickerOnConnect(true);
    }

    // Send system prompt if provided
    const sessionId = useSessionStore.getState().sessionId;
    if (cli.flags.systemPrompt && sessionId) {
      await sendMessageRest(sessionId, cli.flags.systemPrompt);
    }
  } catch (err) {
    // Don't hard-exit — render the app with an error banner
    let message: string;

    if (err instanceof ApiError) {
      if (err.isAuth) {
        message = "Authentication failed. Run with --new or restart to re-authenticate.";
      } else if (err.isServer) {
        message = `Server error (${err.status}). Is the server running at ${useAppStore.getState().serverUrl}?`;
      } else {
        message = `Could not start session: ${err.message}`;
      }
    } else if (err instanceof Error && err.message.includes("fetch")) {
      message = `Cannot reach server at ${useAppStore.getState().serverUrl}. Is it running?`;
    } else {
      message = `Failed to create session: ${err instanceof Error ? err.message : String(err)}`;
    }

    console.error(message);

    if (useAppStore.getState().debug && err instanceof Error) {
      console.error(err.stack);
    }

    useAppStore.getState().addError({
      type: "session",
      message,
      recoverable: true,
      action: err instanceof ApiError && err.isAuth ? "reauth" : "retry",
    });
  }

  // Fire-and-forget: load provider status for honest status bar display
  void (async () => {
    useAppStore.getState().setModelProviderStatus("loading");
    try {
      const { providers } = await listModelProviders();
      const ids = new Set(providers.filter(isProviderConfigured).map((p) => p.id));
      useAppStore.getState().setConfiguredProviderIds(ids);
      useAppStore.getState().setModelProviderStatus("loaded");
    } catch {
      useAppStore.getState().setModelProviderStatus("error");
    }
  })();

  // Render the TUI
  const { waitUntilExit } = render(
    <ErrorBoundary>
      <App />
    </ErrorBoundary>,
    {
      exitOnCtrlC: false,
      patchConsole: false,
    },
  );
  await waitUntilExit();
}

main().catch((err) => {
  if (useAppStore.getState().debug && err instanceof Error) {
    console.error(err.stack);
  } else {
    console.error(err instanceof Error ? err.message : String(err));
  }
  process.exit(1);
});
