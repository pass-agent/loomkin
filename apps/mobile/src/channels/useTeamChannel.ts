import { useEffect, useRef } from "react";
import { Channel } from "phoenix";
import { joinChannel, leaveChannel } from "./socket";
import type { Agent } from "@/lib/types";

interface UseTeamChannelOptions {
  teamId: string | undefined;
  onAgentStatusChange?: (agent: Agent) => void;
  onTaskUpdate?: (data: Record<string, unknown>) => void;
  enabled?: boolean;
}

/**
 * Hook to subscribe to real-time team updates via Phoenix Channels.
 */
export function useTeamChannel({
  teamId,
  onAgentStatusChange,
  onTaskUpdate,
  enabled = true,
}: UseTeamChannelOptions) {
  const channelRef = useRef<Channel | null>(null);

  useEffect(() => {
    if (!teamId || !enabled) return;

    const topic = `team:${teamId}`;
    const channel = joinChannel(topic);
    channelRef.current = channel;

    if (onAgentStatusChange) {
      channel.on("agent_status", (payload: Record<string, unknown>) => {
        onAgentStatusChange(payload as unknown as Agent);
      });
    }

    if (onTaskUpdate) {
      channel.on("task_updated", (payload: Record<string, unknown>) => {
        onTaskUpdate(payload);
      });
    }

    return () => {
      leaveChannel(topic);
      channelRef.current = null;
    };
  }, [teamId, enabled, onAgentStatusChange, onTaskUpdate]);

  return { channel: channelRef.current };
}
