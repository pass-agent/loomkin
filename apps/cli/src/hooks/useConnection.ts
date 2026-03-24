import { useEffect } from "react";
import { useStore } from "zustand";
import { useAppStore } from "../stores/appStore.js";
import { getSocket, disconnectSocket } from "../lib/socket.js";

export function useConnection() {
  const connectionState = useStore(useAppStore, (s) => s.connectionState);
  const errors = useStore(useAppStore, (s) => s.errors);
  const token = useStore(useAppStore, (s) => s.token);

  const isConnected = connectionState === "connected";

  useEffect(() => {
    if (!token) return;

    try {
      getSocket();
    } catch (err) {
      useAppStore.getState().addError({
        type: "network",
        message: err instanceof Error ? err.message : "Connection failed",
        recoverable: true,
        action: "retry",
      });
    }

    return () => {
      disconnectSocket();
    };
  }, [token]);

  return { isConnected, connectionState, errors };
}
