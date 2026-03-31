import { createStore } from "zustand";
import type { Immutable } from "../lib/types/immutable.js";

export interface AgentInfo {
  name: string;
  role: string;
  status: string;
  model?: string;
  teamId?: string;
  currentTool?: string;
  currentTask?: string;
  tokensUsed?: number;
  costUsd?: number;
  lastError?: string;
  pauseQueued?: boolean;
  worktreePath?: string;
  updatedAt: string;
}

export interface AgentStoreState {
  agents: Map<string, AgentInfo>;

  upsertAgent: (name: string, partial: Partial<AgentInfo>) => void;
  removeAgent: (name: string) => void;
  clearAgents: () => void;
  getAgentList: () => AgentInfo[];
}

export const agentStore = createStore<Immutable<AgentStoreState>>((set, get) => ({
  agents: new Map(),

  upsertAgent: (name, partial) =>
    set((state) => {
      const agents = new Map(state.agents);
      const existing = agents.get(name) || {
        name,
        role: "agent",
        status: "idle",
        updatedAt: new Date().toISOString(),
      };
      agents.set(name, {
        ...existing,
        ...partial,
        updatedAt: new Date().toISOString(),
      });
      return { agents };
    }),

  removeAgent: (name) =>
    set((state) => {
      const agents = new Map(state.agents);
      agents.delete(name);
      return { agents };
    }),

  clearAgents: () => set({ agents: new Map() }),

  getAgentList: () => Array.from(get().agents.values()),
}));

export const useAgentStore = agentStore;
