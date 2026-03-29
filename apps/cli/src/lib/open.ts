import { spawn } from "child_process";

export async function openInBrowser(url: string): Promise<void> {
  try {
    const [cmd, ...args] =
      process.platform === "darwin"
        ? ["open", url]
        : process.platform === "win32"
          ? ["cmd", "/c", "start", url]
          : ["xdg-open", url];
    spawn(cmd, args, { stdio: "ignore", detached: true }).unref();
  } catch {
    // Swallow — user can copy the URL manually
  }
}
