import pc from "picocolors";
import { requestDeviceCode, pollDeviceTokenSafe, getCloudBaseUrl } from "./cloudApi.js";
import { setCloudAuth } from "./cloudConfig.js";
import { openInBrowser } from "./open.js";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function runDeviceCodeFlow(addMessage: (msg: string) => void): Promise<boolean> {
  addMessage("Starting loomkin.dev authentication...");

  let codeResponse;
  try {
    codeResponse = await requestDeviceCode();
  } catch (err) {
    addMessage(
      pc.red("Failed to start device code flow: ") +
        (err instanceof Error ? err.message : "Unknown error"),
    );
    return false;
  }

  const {
    device_code,
    user_code,
    verification_uri_complete,
    expires_in,
    interval: initialInterval,
  } = codeResponse;

  // Display the code prominently
  const padded = `   ${user_code}   `;
  const border = "\u2500".repeat(padded.length);
  addMessage(
    [
      "",
      pc.bold("Enter this code at loomkin.dev:"),
      "",
      `  \u250C${border}\u2510`,
      `  \u2502${pc.bold(pc.cyan(padded))}\u2502`,
      `  \u2514${border}\u2518`,
      "",
      pc.dim(`Opening ${verification_uri_complete}`),
      "",
    ].join("\n"),
  );

  // Open browser
  await openInBrowser(verification_uri_complete);

  // Poll for approval
  let intervalMs = initialInterval * 1000;
  const deadline = Date.now() + expires_in * 1000;

  while (Date.now() < deadline) {
    await sleep(intervalMs);

    try {
      const result = await pollDeviceTokenSafe(device_code);

      if (result === "pending") {
        const remaining = Math.ceil((deadline - Date.now()) / 1000);
        addMessage(pc.dim(`Waiting for approval... ${remaining}s remaining`));
        continue;
      }

      if (result === "slow_down") {
        intervalMs += 5000;
        continue;
      }

      // Success — store the token
      const expiresAt = new Date(Date.now() + result.expires_in * 1000).toISOString();
      setCloudAuth({
        accessToken: result.access_token,
        expiresAt,
        scope: result.scope,
        serverUrl: getCloudBaseUrl(),
      });

      addMessage(
        pc.green("Authenticated with loomkin.dev") + "\n" + pc.dim(`Token expires: ${expiresAt}`),
      );
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : "Unknown error";

      if (msg.includes("expired")) {
        addMessage(pc.red("Device code expired. Run /vault auth to try again."));
        return false;
      }

      if (msg.includes("access_denied") || msg.includes("denied")) {
        addMessage(pc.red("Authorization denied. Run /vault auth to try again."));
        return false;
      }

      // Unexpected error — stop polling
      addMessage(pc.red(`Authentication failed: ${msg}`));
      return false;
    }
  }

  addMessage(pc.red("Device code expired. Run /vault auth to try again."));
  return false;
}
