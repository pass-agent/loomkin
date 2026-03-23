import { useEffect, useRef, useCallback } from "react";
import { Channel } from "phoenix";
import { joinChannel, leaveChannel } from "./socket";
import type { Message } from "@/lib/types";

interface UseSessionChannelOptions {
  sessionId: string | undefined;
  onNewMessage?: (message: Message) => void;
  onMessageUpdate?: (message: Message) => void;
  onSessionUpdate?: (data: Record<string, unknown>) => void;
  enabled?: boolean;
}

/**
 * Hook to subscribe to real-time session updates via Phoenix Channels.
 */
export function useSessionChannel({
  sessionId,
  onNewMessage,
  onMessageUpdate,
  onSessionUpdate,
  enabled = true,
}: UseSessionChannelOptions) {
  const channelRef = useRef<Channel | null>(null);

  const sendMessage = useCallback(
    (content: string) => {
      if (!channelRef.current) return;
      channelRef.current.push("new_message", { content });
    },
    []
  );

  useEffect(() => {
    if (!sessionId || !enabled) return;

    const topic = `session:${sessionId}`;
    const channel = joinChannel(topic);
    channelRef.current = channel;

    if (onNewMessage) {
      channel.on("new_message", (payload: Record<string, unknown>) => {
        onNewMessage(payload as unknown as Message);
      });
    }

    if (onMessageUpdate) {
      channel.on("message_updated", (payload: Record<string, unknown>) => {
        onMessageUpdate(payload as unknown as Message);
      });
    }

    if (onSessionUpdate) {
      channel.on("session_updated", (payload: Record<string, unknown>) => {
        onSessionUpdate(payload);
      });
    }

    return () => {
      leaveChannel(topic);
      channelRef.current = null;
    };
  }, [sessionId, enabled, onNewMessage, onMessageUpdate, onSessionUpdate]);

  return { sendMessage, channel: channelRef.current };
}
