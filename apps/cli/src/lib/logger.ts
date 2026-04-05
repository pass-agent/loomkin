import { appendFileSync } from "node:fs";

const LOG_PATH = process.env["LOOMKIN_LOG_FILE"] ?? "/tmp/loomkin-debug.log";
const enabled =
  process.env["LOOMKIN_DEBUG"] === "1" || process.argv.includes("--verbose");

function format(...args: unknown[]): string {
  const ts = new Date().toISOString();
  const msg = args
    .map((a) => (typeof a === "string" ? a : JSON.stringify(a)))
    .join(" ");
  return `[${ts}] ${msg}\n`;
}

export const logger = {
  debug(...args: unknown[]) {
    if (!enabled) return;
    try {
      appendFileSync(LOG_PATH, format(...args));
    } catch {
      // silently ignore write failures
    }
  },
};
