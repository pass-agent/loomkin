import { createStore } from "zustand";
import type {
  Message,
  ToolCall,
  PermissionRequest,
  AskUserQuestion,
  ApprovalRequest,
  SpawnGateRequest,
  PlanMessage,
} from "../lib/types.js";
import { calculateCost } from "../lib/costTracker.js";

export interface SessionState {
  sessionId: string | null;
  messages: Message[];
  isStreaming: boolean;
  isPendingResponse: boolean;
  pendingToolCalls: ToolCall[];
  pendingPermissions: PermissionRequest[];
  pendingQuestions: AskUserQuestion[];
  pendingApprovals: ApprovalRequest[];
  pendingSpawnGates: SpawnGateRequest[];
  pendingPlans: PlanMessage[];
  scrollOffset: number;

  // Token and cost tracking
  totalInputTokens: number;
  totalOutputTokens: number;
  estimatedCostUsd: number;
  contextBudgetPercent: number | null;

  // MCP output tracking
  mcpOutputTotalChars: number;

  setSessionId: (id: string | null) => void;
  addMessage: (message: Message) => void;
  updateMessage: (id: string, partial: Partial<Message>) => void;
  loadMessages: (messages: Message[]) => void;
  clearMessages: () => void;
  setStreaming: (streaming: boolean) => void;
  setPendingResponse: (pending: boolean) => void;
  startStreamingMessage: (id: string) => void;
  appendStreamContent: (id: string, token: string) => void;
  addPendingToolCall: (toolCall: ToolCall) => void;
  removePendingToolCall: (id: string) => void;
  clearPendingToolCalls: () => void;
  addPendingPermission: (request: PermissionRequest) => void;
  removePendingPermission: (id: string) => void;
  clearPendingPermissions: () => void;
  addPendingQuestion: (question: AskUserQuestion) => void;
  removePendingQuestion: (questionId: string) => void;
  clearPendingQuestions: () => void;
  addPendingApproval: (request: ApprovalRequest) => void;
  removePendingApproval: (gateId: string) => void;
  clearPendingApprovals: () => void;
  addPendingSpawnGate: (request: SpawnGateRequest) => void;
  removePendingSpawnGate: (gateId: string) => void;
  clearPendingSpawnGates: () => void;
  addPendingPlan: (plan: PlanMessage) => void;
  removePendingPlan: (planId: string) => void;
  clearPendingPlans: () => void;
  setScrollOffset: (offset: number) => void;
  trackTokenUsage: (inputTokens: number, outputTokens: number, model: string) => void;
  setContextBudgetPercent: (percent: number | null) => void;
  addMcpOutputChars: (n: number) => void;
}

export const sessionStore = createStore<SessionState>((set, _get) => ({
  sessionId: null,
  messages: [],
  isStreaming: false,
  isPendingResponse: false,
  pendingToolCalls: [],
  pendingPermissions: [],
  pendingQuestions: [],
  pendingApprovals: [],
  pendingSpawnGates: [],
  pendingPlans: [],
  scrollOffset: 0,
  totalInputTokens: 0,
  totalOutputTokens: 0,
  estimatedCostUsd: 0,
  contextBudgetPercent: null,
  mcpOutputTotalChars: 0,

  setSessionId: (sessionId) => set({ sessionId }),

  addMessage: (message) =>
    set((state) => ({ messages: [...state.messages, message] })),

  updateMessage: (id, partial) =>
    set((state) => ({
      messages: state.messages.map((m) =>
        m.id === id ? { ...m, ...partial } : m,
      ),
    })),

  loadMessages: (messages) => set({ messages, scrollOffset: 0 }),

  clearMessages: () => set({ messages: [], scrollOffset: 0 }),

  setStreaming: (isStreaming) => set({ isStreaming }),

  setPendingResponse: (isPendingResponse) => set({ isPendingResponse }),

  startStreamingMessage: (id) =>
    set((state) => ({
      messages: [
        ...state.messages,
        {
          id,
          role: "assistant" as const,
          content: "",
          tool_calls: null,
          tool_call_id: null,
          token_count: null,
          agent_name: null,
          inserted_at: new Date().toISOString(),
        },
      ],
    })),

  appendStreamContent: (id, token) =>
    set((state) => ({
      messages: state.messages.map((m) =>
        m.id === id ? { ...m, content: (m.content ?? "") + token } : m,
      ),
    })),

  addPendingToolCall: (toolCall) =>
    set((state) => ({
      pendingToolCalls: [...state.pendingToolCalls, toolCall],
    })),

  removePendingToolCall: (id) =>
    set((state) => ({
      pendingToolCalls: state.pendingToolCalls.filter((tc) => tc.id !== id),
    })),

  clearPendingToolCalls: () => set({ pendingToolCalls: [] }),

  addPendingPermission: (request) =>
    set((state) => ({
      pendingPermissions: [...state.pendingPermissions, request],
    })),

  removePendingPermission: (id) =>
    set((state) => ({
      pendingPermissions: state.pendingPermissions.filter((p) => p.id !== id),
    })),

  addPendingQuestion: (question) =>
    set((state) => ({
      pendingQuestions: [...state.pendingQuestions, question],
    })),

  removePendingQuestion: (questionId) =>
    set((state) => ({
      pendingQuestions: state.pendingQuestions.filter(
        (q) => q.question_id !== questionId,
      ),
    })),

  clearPendingPermissions: () => set({ pendingPermissions: [] }),

  clearPendingQuestions: () => set({ pendingQuestions: [] }),

  addPendingApproval: (request) =>
    set((state) => ({
      pendingApprovals: [...state.pendingApprovals, request],
    })),

  removePendingApproval: (gateId) =>
    set((state) => ({
      pendingApprovals: state.pendingApprovals.filter((a) => a.gate_id !== gateId),
    })),

  clearPendingApprovals: () => set({ pendingApprovals: [] }),

  addPendingSpawnGate: (request) =>
    set((state) => ({
      pendingSpawnGates: [...state.pendingSpawnGates, request],
    })),

  removePendingSpawnGate: (gateId) =>
    set((state) => ({
      pendingSpawnGates: state.pendingSpawnGates.filter((g) => g.gate_id !== gateId),
    })),

  clearPendingSpawnGates: () => set({ pendingSpawnGates: [] }),

  addPendingPlan: (plan) =>
    set((state) => ({
      pendingPlans: [...state.pendingPlans, plan],
    })),

  removePendingPlan: (planId) =>
    set((state) => ({
      pendingPlans: state.pendingPlans.filter((p) => p.plan_id !== planId),
    })),

  clearPendingPlans: () => set({ pendingPlans: [] }),

  setScrollOffset: (scrollOffset) => set({ scrollOffset }),

  trackTokenUsage: (inputTokens, outputTokens, model) =>
    set((state) => {
      const newInput = state.totalInputTokens + inputTokens;
      const newOutput = state.totalOutputTokens + outputTokens;
      const addedCost = calculateCost(model, inputTokens, outputTokens);
      return {
        totalInputTokens: newInput,
        totalOutputTokens: newOutput,
        estimatedCostUsd: state.estimatedCostUsd + addedCost,
      };
    }),

  setContextBudgetPercent: (contextBudgetPercent) => set({ contextBudgetPercent }),

  addMcpOutputChars: (n) =>
    set((state) => ({ mcpOutputTotalChars: state.mcpOutputTotalChars + n })),
}));

export const useSessionStore = sessionStore;
