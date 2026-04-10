import { createStore } from "zustand";
import { agentStore } from "./agentStore.js";

export interface PaneState {
  splitMode: boolean;
  focusedPane: "left" | "right";
  selectedAgent: string | null;
  focusedTarget: string | null;
  rightScrollOffset: number;

  toggleSplitMode: () => void;
  setFocusedPane: (pane: "left" | "right") => void;
  selectAgent: (name: string | null) => void;
  cycleAgent: (direction: 1 | -1) => void;
  setRightScrollOffset: (offset: number) => void;
  setFocusedTarget: (name: string | null) => void;
}

export const paneStore = createStore<PaneState>((set) => ({
  splitMode: false,
  focusedPane: "left",
  selectedAgent: null,
  focusedTarget: null,
  rightScrollOffset: 0,

  toggleSplitMode: () =>
    set((state) => {
      if (state.splitMode) {
        return { splitMode: false, focusedPane: "left" as const };
      }
      const agents = agentStore.getState().getAgentList();
      if (agents.length === 0) {
        return state;
      }
      return {
        splitMode: true,
        selectedAgent: state.selectedAgent ?? agents[0].name,
        rightScrollOffset: 0,
      };
    }),

  setFocusedPane: (pane) => set({ focusedPane: pane }),

  selectAgent: (name) => set({ selectedAgent: name, rightScrollOffset: 0 }),

  cycleAgent: (direction) =>
    set((state) => {
      const agents = agentStore.getState().getAgentList();
      if (agents.length === 0) return state;
      const currentIndex = agents.findIndex((a) => a.name === state.selectedAgent);
      const nextIndex = (currentIndex + direction + agents.length) % agents.length;
      return {
        selectedAgent: agents[nextIndex].name,
        rightScrollOffset: 0,
      };
    }),

  setRightScrollOffset: (offset) => set({ rightScrollOffset: Math.max(0, offset) }),

  setFocusedTarget: (focusedTarget) => set({ focusedTarget }),
}));

export const usePaneStore = paneStore;
