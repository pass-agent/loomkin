#!/usr/bin/env bun
import React from "react";
import { render } from "ink";
import meow from "meow";
import pc from "picocolors";
import { App } from "./app.js";
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
  ApiError,
} from "./lib/api.js";
import { runPrintMode } from "./lib/print.js";

const cli = meow(
  `
  Usage
    $ loomkin [options]
    $ loomkin -p "your prompt"
    $ echo "fix the bug" | loomkin -p -

  Options
    --server, -s                    Server URL (env: LOOMKIN_SERVER_URL)
    --model, -m                     Model to use (default: anthropic:claude-opus-4)
    --mode                          Interaction mode: code, plan, chat (default: code)
    --session                       Resume a specific session by ID
    --new, -n                       Force a new session (ignore last session)
    --resume, -r                    Resume the most recent session (explicit)
    --print, -p                     Non-interactive: send prompt, print response, exit
    --output-format                 Output format for --print: text or json (default: text)
    --cwd, -c                       Override working directory
    --verbose, -v                   Verbose logging (socket events, API calls)
    --debug                         Show full error stack traces and state changes
    --system-prompt                 Prepend a custom system prompt to the session
    --dangerously-skip-permissions  Auto-approve all tool calls (no prompts)
    --allowed-tools                 Comma-separated allowlist of tool names
    --disallowed-tools              Comma-separated denylist of tool names
    --max-turns                     Limit agent turns before stopping

  Examples
    $ loomkin
    $ loomkin --mode plan
    $ loomkin --session abc123
    $ loomkin -p "what is 2+2"
    $ loomkin -p "list files" --output-format json
    $ loomkin --cwd /path/to/project
    $ loomkin --dangerously-skip-permissions -p "refactor auth"
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
    },
  },
);

async function resumeSession(sessionId: string): Promise<boolean> {
  console.error(pc.dim(`Resuming session ${sessionId.slice(0, 8)}…`));

  try {
    await getSession(sessionId);
    useSessionStore.getState().setSessionId(sessionId);

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

  if (cli.flags.resume || lastSession) {
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

  // Check auth — run setup wizard if needed
  if (!isAuthenticated()) {
    const success = await runSetupWizard();
    if (!success) {
      process.exit(1);
    }
    // Reload token into store
    const { getConfig } = await import("./lib/config.js");
    useAppStore.getState().setToken(getConfig().token);
  }

  // Non-interactive print mode
  if (cli.flags.print != null) {
    let prompt = cli.flags.print;

    // Read from stdin if "-" is passed
    if (prompt === "-") {
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

    try {
      const sessionId = await resolveSessionId();

      // Send system prompt first if provided
      if (cli.flags.systemPrompt && sessionId) {
        await sendMessageRest(sessionId, cli.flags.systemPrompt);
      }

      await runPrintMode({
        prompt,
        outputFormat: cli.flags.outputFormat as "text" | "json",
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
    }
    process.exit(0);
  }

  // Interactive mode — create or resume session
  try {
    await resolveSessionId();

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

  // Render the TUI
  const { waitUntilExit } = render(<App />, {
    exitOnCtrlC: false,
    patchConsole: false,
  });
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
