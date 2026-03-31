import { createStore } from "zustand";
import type { Immutable } from "../lib/types/immutable.js";
import type { ConversationInfo, ConversationTurn } from "../lib/types.js";

const MAX_COMPLETED = 20;
const MAX_TURNS_PER_CONVERSATION = 500;

function makeTurn(
  conversation_id: string,
  speaker: string,
  content: string,
  round: number,
  type: ConversationTurn["type"],
  extra?: { reaction_type?: string; reason?: string },
): ConversationTurn {
  return {
    conversation_id,
    speaker,
    content,
    round,
    type,
    reaction_type: extra?.reaction_type,
    reason: extra?.reason,
    timestamp: new Date().toISOString(),
  };
}

function pruneCompleted(conversations: Map<string, ConversationInfo>): Map<string, ConversationInfo> {
  const completed = [...conversations.values()]
    .filter((c) => c.status === "completed" || c.status === "terminated")
    .sort((a, b) => (a.ended_at ?? "").localeCompare(b.ended_at ?? ""));

  while (completed.length > MAX_COMPLETED) {
    const oldest = completed.shift()!;
    conversations.delete(oldest.conversation_id);
  }

  return conversations;
}

function cappedTurns(turns: ConversationTurn[]): ConversationTurn[] {
  return turns.length > MAX_TURNS_PER_CONVERSATION
    ? turns.slice(-MAX_TURNS_PER_CONVERSATION)
    : turns;
}

export interface ConversationStoreState {
  conversations: Map<string, ConversationInfo>;
  activeConversationId: string | null;

  startConversation: (info: {
    conversation_id: string;
    topic: string;
    participants: string[];
    strategy?: string;
    team_id: string;
  }) => void;
  addTurn: (turn: ConversationTurn) => void;
  addReaction: (data: {
    conversation_id: string;
    agent_name: string;
    reaction_type: string;
    brief: string;
  }) => void;
  addYield: (data: {
    conversation_id: string;
    agent_name: string;
    reason?: string;
  }) => void;
  advanceRound: (conversation_id: string, round: number) => void;
  setSummarizing: (conversation_id: string) => void;
  endConversation: (data: {
    conversation_id: string;
    outcome?: string;
    summary?: ConversationInfo["summary"];
  }) => void;
  terminateConversation: (conversation_id: string, reason?: string) => void;
  setActiveConversation: (id: string | null) => void;
  getActive: () => ConversationInfo | null;
  getList: () => ConversationInfo[];
}

export const conversationStore = createStore<Immutable<ConversationStoreState>>(
  (set, get) => ({
    conversations: new Map(),
    activeConversationId: null,

    startConversation: (info) =>
      set((state) => {
        const conversations = new Map(state.conversations);
        conversations.set(info.conversation_id, {
          ...info,
          current_round: 1,
          status: "active",
          turns: [],
          started_at: new Date().toISOString(),
        });
        // Only auto-focus if user hasn't explicitly pinned a conversation
        const activeConversationId =
          state.activeConversationId === null
            ? info.conversation_id
            : state.activeConversationId;
        return { conversations, activeConversationId };
      }),

    addTurn: (turn) =>
      set((state) => {
        const conversations = new Map(state.conversations);
        const conv = conversations.get(turn.conversation_id);
        if (!conv) return state;
        conversations.set(turn.conversation_id, {
          ...conv,
          turns: cappedTurns([...conv.turns, turn]),
        });
        return { conversations };
      }),

    addReaction: (data) =>
      set((state) => {
        const conversations = new Map(state.conversations);
        const conv = conversations.get(data.conversation_id);
        if (!conv) return state;
        const turn = makeTurn(
          data.conversation_id,
          data.agent_name,
          data.brief,
          conv.current_round,
          "reaction",
          { reaction_type: data.reaction_type },
        );
        conversations.set(data.conversation_id, {
          ...conv,
          turns: cappedTurns([...conv.turns, turn]),
        });
        return { conversations };
      }),

    addYield: (data) =>
      set((state) => {
        const conversations = new Map(state.conversations);
        const conv = conversations.get(data.conversation_id);
        if (!conv) return state;
        const turn = makeTurn(
          data.conversation_id,
          data.agent_name,
          data.reason ?? "passed",
          conv.current_round,
          "yield",
          { reason: data.reason },
        );
        conversations.set(data.conversation_id, {
          ...conv,
          turns: cappedTurns([...conv.turns, turn]),
        });
        return { conversations };
      }),

    advanceRound: (conversation_id, round) =>
      set((state) => {
        const conversations = new Map(state.conversations);
        const conv = conversations.get(conversation_id);
        if (!conv) return state;
        conversations.set(conversation_id, {
          ...conv,
          current_round: round,
        });
        return { conversations };
      }),

    setSummarizing: (conversation_id) =>
      set((state) => {
        const conversations = new Map(state.conversations);
        const conv = conversations.get(conversation_id);
        if (!conv) return state;
        conversations.set(conversation_id, {
          ...conv,
          status: "summarizing",
        });
        return { conversations };
      }),

    endConversation: (data) =>
      set((state) => {
        const conversations = new Map(state.conversations);
        const conv = conversations.get(data.conversation_id);
        if (!conv) return state;
        conversations.set(data.conversation_id, {
          ...conv,
          status: "completed",
          summary: data.summary,
          ended_at: new Date().toISOString(),
        });
        return { conversations: pruneCompleted(conversations) };
      }),

    terminateConversation: (conversation_id, _reason) =>
      set((state) => {
        const conversations = new Map(state.conversations);
        const conv = conversations.get(conversation_id);
        if (!conv) return state;
        conversations.set(conversation_id, {
          ...conv,
          status: "terminated",
          ended_at: new Date().toISOString(),
        });
        return { conversations: pruneCompleted(conversations) };
      }),

    setActiveConversation: (id) => set({ activeConversationId: id }),

    getActive: () => {
      const { conversations, activeConversationId } = get();
      if (!activeConversationId) return null;
      return conversations.get(activeConversationId) ?? null;
    },

    getList: () => Array.from(get().conversations.values()),
  }),
);

export const useConversationStore = conversationStore;
