import { createStore } from "zustand";
import { joinChannel, leaveChannel } from "../lib/socket.js";
import { useAppStore } from "./appStore.js";
import type { Channel } from "phoenix";
import type { Immutable } from "../lib/types/immutable.js";

export interface ChannelStoreState {
  channel: Channel | null;
  topic: string | null;

  connect: (sessionId: string) => void;
  disconnect: () => void;
  getChannel: () => Channel | null;
}

export const channelStore = createStore<Immutable<ChannelStoreState>>((set, get) => ({
  channel: null,
  topic: null,

  connect: (sessionId: string) => {
    const topic = `session:${sessionId}`;
    const current = get();

    // Already connected to this topic
    if (current.topic === topic && current.channel !== null) return;

    // Disconnect existing channel if switching sessions
    if (current.topic && current.topic !== topic) {
      leaveChannel(current.topic);
    }

    const channel = joinChannel(topic, {}, (resp) => {
      // Sync model from join response
      if (resp.model && typeof resp.model === "string") {
        useAppStore.getState().setModel(resp.model as string);
      }
    });

    set({ channel, topic });
  },

  disconnect: () => {
    const { topic } = get();
    if (topic) {
      leaveChannel(topic);
    }
    set({ channel: null, topic: null });
  },

  getChannel: () => get().channel,
}));

export const useChannelStore = channelStore;
