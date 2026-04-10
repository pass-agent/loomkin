import Conf from "conf";
import { join } from "path";
import { homedir } from "os";
import { DEFAULT_MODE, DEFAULT_MODEL, DEFAULT_SERVER_URL } from "./constants.js";

export interface AgentCostEntry {
  costUsd: number;
  tokensUsed: number;
}

export interface LoomkinConfig {
  serverUrl: string;
  token: string | null;
  defaultMode: string;
  defaultModel: string;
  lastSessionId: string | null;
  theme: string;
  keybindMode: "default" | "vim";
  agentCosts: Record<string, Record<string, AgentCostEntry>>;
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
    agentCosts: {},
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

export function getHistoryPath(): string {
  return join(homedir(), ".loomkin", "history.json");
}

const MAX_COST_SESSIONS = 10;

export function getAgentCostsForSession(sessionId: string): Record<string, AgentCostEntry> {
  const allCosts = config.get("agentCosts") ?? {};
  return allCosts[sessionId] ?? {};
}

export function setAgentCostForSession(
  sessionId: string,
  agentName: string,
  costUsd: number,
  tokensUsed: number,
): void {
  const allCosts: Record<string, Record<string, AgentCostEntry>> = config.get("agentCosts") ?? {};

  if (!allCosts[sessionId]) {
    allCosts[sessionId] = {};
  }
  allCosts[sessionId][agentName] = { costUsd, tokensUsed };

  // Trim to last MAX_COST_SESSIONS sessions
  const keys = Object.keys(allCosts);
  if (keys.length > MAX_COST_SESSIONS) {
    const toRemove = keys.slice(0, keys.length - MAX_COST_SESSIONS);
    for (const k of toRemove) {
      delete allCosts[k];
    }
  }

  config.set("agentCosts", allCosts);
}
