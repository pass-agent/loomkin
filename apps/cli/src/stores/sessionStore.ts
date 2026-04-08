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

function makeStreamingMessage(id: string): Message {
  return {
    id,
    role: "assistant",
    content: "",
    tool_calls: null,
    tool_call_id: null,
    token_count: null,
    agent_name: null,
    inserted_at: new Date().toISOString(),
  };
}

function generateStreamingMessageId(): string {
  return `stream-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

export interface SessionState {
  sessionId: string | null;
  messages: Message[];
  isStreaming: boolean;
  isPendingResponse: boolean;
  currentStreamingMessageId: string | null;
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

  // Recent file path tracking (for post-compact re-injection)
  recentFilePaths: string[];

  // Background memory extraction tracking
  lastExtractionTokenCount: number;
  toolCallsSinceExtraction: number;
  extractionInProgress: boolean;

  // Hook progress tracking
  inProgressHookCounts: Map<string, number>;

  setSessionId: (id: string | null) => void;
  addMessage: (message: Message) => void;
  updateMessage: (id: string, partial: Partial<Message>) => void;
  loadMessages: (messages: Message[]) => void;
  clearMessages: () => void;
  setStreaming: (streaming: boolean) => void;
  setPendingResponse: (pending: boolean) => void;
  startStreamingMessage: (id: string) => void;
  ensureStreamingMessage: (id?: string | null) => string;
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
  trackFilePath: (path: string) => void;
  incrementToolCallsForExtraction: () => void;
  setExtractionInProgress: (v: boolean) => void;
  recordExtraction: (currentTokenCount: number) => void;
  hookStarted: (toolUseId: string) => void;
  hookCompleted: (toolUseId: string) => void;
}

export const sessionStore = createStore<SessionState>((set, _get) => ({
  sessionId: null,
  messages: [],
  isStreaming: false,
  isPendingResponse: false,
  currentStreamingMessageId: null,
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
  recentFilePaths: [],
  lastExtractionTokenCount: 0,
  toolCallsSinceExtraction: 0,
  extractionInProgress: false,
  inProgressHookCounts: new Map(),

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

  setStreaming: (isStreaming) =>
    set(isStreaming ? { isStreaming } : { isStreaming, currentStreamingMessageId: null }),

  setPendingResponse: (isPendingResponse) => set({ isPendingResponse }),

  startStreamingMessage: (id) =>
    set((state) => ({
      currentStreamingMessageId: id,
      messages: [...state.messages, makeStreamingMessage(id)],
    })),

  ensureStreamingMessage: (id) => {
    const state = _get();
    const streamId = id ?? state.currentStreamingMessageId ?? generateStreamingMessageId();
    const hasMessage = state.messages.some((message) => message.id === streamId);

    if (!hasMessage || state.currentStreamingMessageId !== streamId) {
      set({
        currentStreamingMessageId: streamId,
        messages: hasMessage
          ? state.messages
          : [...state.messages, makeStreamingMessage(streamId)],
      });
    }

    return streamId;
  },

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

  trackFilePath: (path) =>
    set((state) => {
      const paths = [path, ...state.recentFilePaths.filter((p) => p !== path)].slice(0, 10);
      return { recentFilePaths: paths };
    }),

  incrementToolCallsForExtraction: () =>
    set((state) => ({ toolCallsSinceExtraction: state.toolCallsSinceExtraction + 1 })),

  setExtractionInProgress: (extractionInProgress) => set({ extractionInProgress }),

  recordExtraction: (currentTokenCount) =>
    set({ lastExtractionTokenCount: currentTokenCount, toolCallsSinceExtraction: 0 }),

  hookStarted: (toolUseId) =>
    set((state) => {
      const next = new Map(state.inProgressHookCounts);
      next.set(toolUseId, (next.get(toolUseId) ?? 0) + 1);
      return { inProgressHookCounts: next };
    }),

  hookCompleted: (toolUseId) =>
    set((state) => {
      const next = new Map(state.inProgressHookCounts);
      const current = next.get(toolUseId) ?? 0;
      next.set(toolUseId, Math.max(0, current - 1));
      return { inProgressHookCounts: next };
    }),
}));

export const useSessionStore = sessionStore;
