import { getConfig } from "./config.js";

export function getApiBaseUrl(): string {
  return process.env.LOOMKIN_SERVER_URL ?? getConfig().serverUrl;
}

export function getApiUrl(): string {
  return `${getApiBaseUrl()}/api/v1`;
}

export function getWsUrl(): string {
  const base = getApiBaseUrl().replace(/^https?:\/\//, "");
  const protocol = getApiBaseUrl().startsWith("https") ? "wss" : "ws";
  return `${protocol}://${base}/socket`;
}

const isDev = !process.env.NODE_ENV || process.env.NODE_ENV === "development";
export const DEFAULT_SERVER_URL =
  process.env.LOOMKIN_SERVER_URL ??
  (isDev ? "https://loom.test" : "https://api.loomkin.dev");
export const DEFAULT_MODE = "code";
export const DEFAULT_MODEL = "anthropic:claude-opus-4";

export const MODES = ["code", "plan", "chat"] as const;
export type Mode = (typeof MODES)[number];
