import { Socket, Channel } from "phoenix";
import { getWsUrl } from "./urls.js";
import { useAppStore } from "../stores/appStore.js";

const MAX_RECONNECT_ATTEMPTS = 10;

let socket: Socket | null = null;
const activeChannels = new Map<string, Channel>();

function log(...args: unknown[]) {
  if (useAppStore.getState().verbose) {
    console.error("[socket]", ...args);
  }
}

/**
 * Get or create the Phoenix Socket connection.
 * Automatically authenticates with the current user's token.
 */
export function getSocket(): Socket {
  if (socket?.isConnected()) {
    return socket;
  }

  const store = useAppStore.getState();
  const token = store.token;

  store.setConnectionState("connecting");
  log("connecting to", getWsUrl());

  socket = new Socket(getWsUrl(), {
    params: { token: token ?? "" },
    reconnectAfterMs: (tries: number) =>
      [1000, 2000, 5000, 10000][Math.min(tries - 1, 3)],
  });

  socket.onOpen(() => {
    log("connected");
    useAppStore.getState().setConnectionState("connected");
  });

  socket.onError(() => {
    const state = useAppStore.getState();
    // Don't downgrade from "connected" — transient errors during an
    // active connection are handled by Phoenix's heartbeat/reconnect.
    if (state.connectionState === "connected") return;

    state.incrementReconnectAttempts();

    if (state.reconnectAttempts + 1 >= MAX_RECONNECT_ATTEMPTS) {
      state.setConnectionState("disconnected");
      state.addError({
        type: "network",
        message: `Connection lost after ${MAX_RECONNECT_ATTEMPTS} retries`,
        recoverable: true,
        action: "retry",
      });
    } else {
      state.setConnectionState("reconnecting");
    }
  });

  socket.onClose(() => {
    const state = useAppStore.getState();
    // Only mark as reconnecting if we were connected (not if already
    // reconnecting or disconnected). During Phoenix reconnect cycles,
    // the old transport's onClose can fire after the new onOpen.
    if (state.connectionState === "connected") {
      state.setConnectionState("reconnecting");
      // Only clear channels on a real disconnect, not stale close events
      clearChannels();
    }
  });

  socket.connect();
  return socket;
}

/**
 * Clear the channel cache without leaving (socket already closed).
 */
function clearChannels(): void {
  activeChannels.clear();
}

/**
 * Join a Phoenix channel with the given topic.
 * Returns the existing channel if already joined.
 */
export function joinChannel(
  topic: string,
  params: Record<string, unknown> = {},
  onJoin?: (resp: Record<string, unknown>) => void,
): Channel {
  const existing = activeChannels.get(topic);
  if (existing) return existing;

  const s = getSocket();
  const channel = s.channel(topic, params);

  channel
    .join()
    .receive("ok", (resp: Record<string, unknown>) => {
      log("joined", topic);
      onJoin?.(resp);
    })
    .receive("error", (resp: Record<string, unknown>) => {
      activeChannels.delete(topic);
      const reason =
        typeof resp?.reason === "string"
          ? resp.reason
          : "connection refused";
      useAppStore.getState().addError({
        type: "session",
        message: `Could not join ${topic} — ${reason}`,
        recoverable: true,
        action: "retry",
      });
    })
    .receive("timeout", () => {
      activeChannels.delete(topic);
      useAppStore.getState().addError({
        type: "session",
        message: `Timeout joining ${topic}`,
        recoverable: true,
        action: "retry",
      });
    });

  activeChannels.set(topic, channel);
  return channel;
}

/**
 * Leave a Phoenix channel.
 */
export function leaveChannel(topic: string): void {
  const channel = activeChannels.get(topic);
  if (channel) {
    channel.leave();
    activeChannels.delete(topic);
  }
}

/**
 * Disconnect the socket and clean up all channels.
 */
export function disconnectSocket(): void {
  activeChannels.forEach((channel) => channel.leave());
  activeChannels.clear();
  if (socket) {
    socket.disconnect();
    socket = null;
  }
  useAppStore.getState().setConnectionState("disconnected");
}

/**
 * Reconnect with a new token (e.g., after login).
 */
export function reconnectSocket(): void {
  disconnectSocket();
  getSocket();
}
