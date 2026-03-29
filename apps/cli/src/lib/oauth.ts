import * as p from "@clack/prompts";
import pc from "picocolors";
import { startOAuthFlow, getOAuthStatus, submitOAuthPaste, ApiError } from "./api.js";
import { openInBrowser } from "./open.js";

// ---------------------------------------------------------------------------
// Headless OAuth — for use inside the running Ink app (no clack, no stdin conflict)
// ---------------------------------------------------------------------------

async function runRedirectHeadless(
  provider: string,
  displayName: string,
  authorizeUrl: string,
  addMessage: (msg: string) => void,
): Promise<boolean> {
  await openInBrowser(authorizeUrl);
  addMessage(
    `Browser opened for ${displayName} authorization.\n` +
      `If it didn't open, visit:\n  ${authorizeUrl}`,
  );

  let seenFlowActive = false;
  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    await sleep(POLL_INTERVAL_MS);
    try {
      const status = await getOAuthStatus(provider);
      if (status.flow_active) seenFlowActive = true;
      if (seenFlowActive && !status.flow_active) {
        if (status.connected) {
          addMessage(`✔ ${displayName} connected successfully.`);
          return true;
        }
        break;
      }
    } catch {
      // transient network error — keep polling
    }
  }

  addMessage(`${displayName} authorization timed out. Use ctrl+o to try again.`);
  return false;
}

async function runPasteBackHeadless(
  provider: string,
  displayName: string,
  authorizeUrl: string,
  addMessage: (msg: string) => void,
  captureInput: ((callback: (input: string) => void) => void) | undefined,
): Promise<boolean> {
  addMessage(
    [
      `Authorize ${displayName} at:`,
      `  ${authorizeUrl}`,
      ``,
      `After authorizing, copy the code#state string from the redirect page and paste it below:`,
    ].join("\n"),
  );

  if (!captureInput) {
    addMessage("Cannot capture input in this context. OAuth flow cancelled.");
    return false;
  }

  return new Promise<boolean>((resolve) => {
    captureInput(async (input) => {
      addMessage("Verifying code...");
      try {
        await submitOAuthPaste(provider, input);
        addMessage(`✔ ${displayName} connected successfully.`);
        resolve(true);
      } catch (err) {
        if (err instanceof ApiError) {
          const errorStr = (err.parsedBody?.error as string) ?? "";
          if (errorStr.includes("no active") || err.status === 400) {
            addMessage("OAuth flow expired. Use ctrl+o to start a new flow.");
          } else if (errorStr.includes("state")) {
            addMessage(
              "Code validation failed — the pasted string may be incorrect or for a different session.",
            );
          } else {
            addMessage(err.message);
          }
        } else {
          addMessage(err instanceof Error ? err.message : "Unknown error");
        }
        resolve(false);
      }
    });
  });
}

export async function runOAuthFlowInApp(
  provider: string,
  displayName: string,
  addMessage: (msg: string) => void,
  captureInput: ((callback: (input: string) => void) => void) | undefined,
): Promise<boolean> {
  addMessage(`Starting ${displayName} OAuth...`);

  let startResult;
  try {
    startResult = await startOAuthFlow(provider);
  } catch (err) {
    addMessage(
      `Failed to start OAuth flow: ${err instanceof Error ? err.message : "Unknown error"}`,
    );
    return false;
  }

  if (startResult.flow_type === "paste_back") {
    return runPasteBackHeadless(provider, displayName, startResult.url, addMessage, captureInput);
  }
  return runRedirectHeadless(provider, displayName, startResult.url, addMessage);
}

const POLL_INTERVAL_MS = 2000;
const POLL_MAX_ATTEMPTS = 60; // 2 minutes total

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runRedirectOAuthFlow(
  provider: string,
  displayName: string,
  authorizeUrl: string,
): Promise<boolean> {
  await openInBrowser(authorizeUrl);
  p.log.step(`Browser opened for ${displayName} authorization.`);
  p.log.info(
    pc.dim(`If the browser did not open, visit:\n  ${pc.cyan(authorizeUrl)}`),
  );

  const spinner = p.spinner();
  spinner.start("Waiting for authorization...");

  let seenFlowActive = false;

  for (let i = 0; i < POLL_MAX_ATTEMPTS; i++) {
    await sleep(POLL_INTERVAL_MS);
    try {
      const status = await getOAuthStatus(provider);

      if (status.flow_active) {
        seenFlowActive = true;
      }

      // Only claim success after observing the flow complete (active → inactive)
      if (seenFlowActive && !status.flow_active) {
        if (status.connected) {
          spinner.stop(`${displayName} connected!`);
          p.log.success(`${displayName} connected successfully.`);
          return true;
        }
        // Flow ended without connecting — authorization was denied or failed
        break;
      }
    } catch {
      // Transient network error — continue polling
    }
  }

  spinner.stop("Authorization timed out.");
  p.log.warn("The authorization window expired.");

  const retry = await p.confirm({ message: "Would you like to try again?" });
  if (p.isCancel(retry) || !retry) return false;
  return runOAuthFlow(provider, displayName);
}

async function runPasteBackOAuthFlow(
  provider: string,
  displayName: string,
  authorizeUrl: string,
): Promise<boolean> {
  p.log.step(`Authorize ${displayName} at the following URL:`);
  p.log.message(`  ${pc.cyan(authorizeUrl)}`);
  p.log.info(
    pc.dim(
      `${displayName} will redirect to their own site and show a code string.\nCopy the entire "code#state" string from that page.`,
    ),
  );

  const input = await p.text({
    message: `Paste the code string from your browser:`,
    placeholder: "abc123...#xyz456...",
    validate: (v) => {
      if (!v) return "Required";
      if (!v.includes("#")) return 'Expected format: "code#state" — must contain "#"';
    },
  });

  if (p.isCancel(input)) return false;

  const spinner = p.spinner();
  spinner.start("Verifying code...");

  try {
    await submitOAuthPaste(provider, input as string);
    spinner.stop(`${displayName} connected!`);
    p.log.success(`${displayName} connected successfully.`);
    return true;
  } catch (err) {
    spinner.stop("Connection failed.");

    if (err instanceof ApiError) {
      const body = err.parsedBody;
      const errorStr = (body?.error as string) ?? "";
      if (errorStr.includes("no active") || err.status === 400) {
        p.log.error("OAuth flow expired. Please start a new flow.");
      } else if (errorStr.includes("state")) {
        p.log.error(
          "Code validation failed — the pasted string may be incorrect or for a different session.",
        );
      } else {
        p.log.error(err.message);
      }
    } else {
      p.log.error(err instanceof Error ? err.message : "Unknown error");
    }

    const retry = await p.confirm({ message: "Would you like to try again?" });
    if (p.isCancel(retry) || !retry) return false;
    return runOAuthFlow(provider, displayName);
  }
}

export async function runOAuthFlow(
  provider: string,
  displayName: string,
): Promise<boolean> {
  const spinner = p.spinner();
  spinner.start(`Starting ${displayName} OAuth flow...`);

  let startResult;
  try {
    startResult = await startOAuthFlow(provider);
    spinner.stop("Authorization URL ready.");
  } catch (err) {
    spinner.stop("Failed to start OAuth flow.");
    p.log.error(err instanceof Error ? err.message : "Unknown error");
    return false;
  }

  const ok =
    startResult.flow_type === "paste_back"
      ? await runPasteBackOAuthFlow(provider, displayName, startResult.url)
      : await runRedirectOAuthFlow(provider, displayName, startResult.url);

  // Clack writes directly to stdout, bypassing Ink's render loop.
  // Print a blank separator so the caller's addSystemMessage triggers a
  // full Ink re-render and restores keyboard input.
  p.log.message("");

  return ok;
}
