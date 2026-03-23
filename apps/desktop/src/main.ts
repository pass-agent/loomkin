/**
 * Loomkin Desktop - Tauri Bridge
 *
 * In development, the devUrl in tauri.dev.conf.json loads the Phoenix app
 * directly at http://loom.test:4200, so this file is primarily used for
 * the production build's static HTML fallback.
 *
 * This module also exports utility functions that the Phoenix LiveView app
 * can call to interact with native desktop features via window.__TAURI__.
 */

/**
 * Check if we are running inside a Tauri webview.
 */
export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI__" in window;
}

/**
 * Send a native desktop notification via Tauri.
 * Falls back silently if not running in Tauri.
 */
export async function sendNotification(
  title: string,
  body: string
): Promise<void> {
  if (!isTauri()) return;

  try {
    const { invoke } = await import("@tauri-apps/api/core");
    await invoke("send_notification", { title, body });
  } catch (err) {
    console.warn("Failed to send native notification:", err);
  }
}

/**
 * Check for application updates manually.
 * Returns update info if available, null if up to date.
 */
export async function checkForUpdates(): Promise<{
  currentVersion: string;
  availableVersion: string;
} | null> {
  if (!isTauri()) return null;

  try {
    const { invoke } = await import("@tauri-apps/api/core");
    const result = await invoke<{
      current_version: string;
      available_version: string;
    } | null>("check_for_updates");

    if (result) {
      return {
        currentVersion: result.current_version,
        availableVersion: result.available_version,
      };
    }
    return null;
  } catch (err) {
    console.warn("Failed to check for updates:", err);
    return null;
  }
}

/**
 * Expose bridge functions on the window for the Phoenix LiveView app to call.
 * The Phoenix app can check for `window.LoomkinDesktop` to detect native features.
 */
if (isTauri()) {
  (window as any).LoomkinDesktop = {
    isTauri: true,
    sendNotification,
    checkForUpdates,
  };

  console.log("Loomkin Desktop: Tauri bridge initialized");
}
