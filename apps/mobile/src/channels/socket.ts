import { Socket, Channel } from "phoenix";
import { WS_URL } from "@/lib/constants";
import { useAuthStore } from "@/stores/authStore";

let socket: Socket | null = null;
const activeChannels = new Map<string, Channel>();

/**
 * Get or create the Phoenix Socket connection.
 * Automatically authenticates with the current user's token.
 */
export function getSocket(): Socket {
  if (socket?.isConnected()) {
    return socket;
  }

  const token = useAuthStore.getState().token;

  socket = new Socket(WS_URL, {
    params: { token: token ?? "" },
    reconnectAfterMs: (tries: number) => [1000, 2000, 5000, 10000][Math.min(tries - 1, 3)],
  });

  socket.onError(() => {
    console.warn("[Socket] Connection error");
  });

  socket.onClose(() => {
    console.log("[Socket] Connection closed");
  });

  socket.connect();
  return socket;
}

/**
 * Join a Phoenix channel with the given topic.
 * Returns the existing channel if already joined.
 */
export function joinChannel(topic: string, params: Record<string, unknown> = {}): Channel {
  const existing = activeChannels.get(topic);
  if (existing) return existing;

  const s = getSocket();
  const channel = s.channel(topic, params);

  channel
    .join()
    .receive("ok", () => {
      console.log(`[Channel] Joined ${topic}`);
    })
    .receive("error", (resp: Record<string, unknown>) => {
      console.error(`[Channel] Failed to join ${topic}:`, resp);
      activeChannels.delete(topic);
    })
    .receive("timeout", () => {
      console.warn(`[Channel] Timeout joining ${topic}`);
      activeChannels.delete(topic);
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
}

/**
 * Reconnect with a new token (e.g., after login).
 */
export function reconnectSocket(): void {
  disconnectSocket();
  getSocket();
}
