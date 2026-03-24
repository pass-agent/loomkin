import Conf from "conf";
import { DEFAULT_MODE, DEFAULT_MODEL, DEFAULT_SERVER_URL } from "./constants.js";

export interface LoomkinConfig {
  serverUrl: string;
  token: string | null;
  defaultMode: string;
  defaultModel: string;
  lastSessionId: string | null;
  theme: string;
  keybindMode: "default" | "vim";
}

const config = new Conf<LoomkinConfig>({
  projectName: "loomkin",
  defaults: {
    serverUrl: DEFAULT_SERVER_URL,
    token: null,
    defaultMode: DEFAULT_MODE,
    defaultModel: DEFAULT_MODEL,
    lastSessionId: null,
    theme: "loomkin",
    keybindMode: "default",
  },
});

export function getConfig(): LoomkinConfig {
  return config.store;
}

export function setConfig(partial: Partial<LoomkinConfig>): void {
  for (const [key, value] of Object.entries(partial)) {
    config.set(key as keyof LoomkinConfig, value);
  }
}

export function isAuthenticated(): boolean {
  return config.get("token") !== null;
}

export function clearAuth(): void {
  config.set("token", null);
}

export function getLastSessionId(): string | null {
  return config.get("lastSessionId") ?? null;
}

export function setLastSessionId(sessionId: string | null): void {
  config.set("lastSessionId", sessionId);
}
