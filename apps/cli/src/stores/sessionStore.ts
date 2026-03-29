import { createStore } from "zustand";
import type { Message, ToolCall, PermissionRequest, AskUserQuestion } from "../lib/types.js";

export interface SessionState {
  sessionId: string | null;
  messages: Message[];
  isStreaming: boolean;
  isPendingResponse: boolean;
  pendingToolCalls: ToolCall[];
  pendingPermissions: PermissionRequest[];
  pendingQuestions: AskUserQuestion[];
  scrollOffset: number;

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
  setScrollOffset: (offset: number) => void;
}

export const sessionStore = createStore<SessionState>((set) => ({
  sessionId: null,
  messages: [],
  isStreaming: false,
  isPendingResponse: false,
  pendingToolCalls: [],
  pendingPermissions: [],
  pendingQuestions: [],
  scrollOffset: 0,

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

  setScrollOffset: (scrollOffset) => set({ scrollOffset }),
}));

export const useSessionStore = sessionStore;
