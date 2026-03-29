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
