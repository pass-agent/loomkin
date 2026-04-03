import { useEffect } from "react";
import { useStore } from "zustand";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAppStore } from "../stores/appStore.js";
import { useChannelStore } from "../stores/channelStore.js";

/**
 * Sole owner of the Phoenix channel lifecycle.
 * Connects when session + socket are ready, disconnects on teardown.
 * All other hooks read the channel from channelStore — they never join/leave.
 */
export function useChannelLifecycle() {
  const sessionId = useStore(useSessionStore, (s) => s.sessionId);
  const connectionState = useStore(useAppStore, (s) => s.connectionState);
  const isConnected = connectionState === "connected";

  useEffect(() => {
    if (!sessionId || !isConnected) return;

    useChannelStore.getState().connect(sessionId);

    return () => {
      useChannelStore.getState().disconnect();
    };
  }, [sessionId, isConnected]);
}
