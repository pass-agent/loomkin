import React from "react";
import { Box, Text } from "ink";
import { useStore } from "zustand";
import { useAppStore } from "../stores/appStore.js";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAgentStore } from "../stores/agentStore.js";
import { usePaneStore } from "../stores/paneStore.js";

export function StatusBar() {
  const connectionState = useStore(useAppStore, (s) => s.connectionState);
  const reconnectAttempts = useStore(useAppStore, (s) => s.reconnectAttempts);
  const mode = useStore(useAppStore, (s) => s.mode);
  const model = useStore(useAppStore, (s) => s.model);
  const sessionId = useStore(useSessionStore, (s) => s.sessionId);
  const isStreaming = useStore(useSessionStore, (s) => s.isStreaming);
  const messages = useStore(useSessionStore, (s) => s.messages);
  const agentCount = useStore(useAgentStore, (s) => s.agents.size);
  const workingCount = useStore(useAgentStore, (s) => {
    let count = 0;
    for (const agent of s.agents.values()) {
      if (agent.status === "working") count++;
    }
    return count;
  });
  const splitMode = useStore(usePaneStore, (s) => s.splitMode);
  const selectedAgent = useStore(usePaneStore, (s) => s.selectedAgent);
  const keybindMode = useStore(useAppStore, (s) => s.keybindMode);
  const vimMode = useStore(useAppStore, (s) => s.vimMode);

  const isConnected = connectionState === "connected";
  const isReconnecting =
    connectionState === "reconnecting" || connectionState === "connecting";

  // Determine streaming status text
  const lastMessage = messages[messages.length - 1];
  const hasStreamingContent =
    isStreaming &&
    lastMessage?.role === "assistant" &&
    (lastMessage.content?.length ?? 0) > 0;

  const dotColor = isConnected ? "green" : isReconnecting ? "yellow" : "red";
  const dotChar = isConnected ? "●" : isReconnecting ? "◐" : "○";

  return (
    <Box
      borderStyle="single"
      borderColor="gray"
      paddingX={1}
      justifyContent="space-between"
    >
      <Box gap={2}>
        <Text color={dotColor}>{dotChar}</Text>
        {isReconnecting && (
          <Text color="yellow">
            reconnecting{reconnectAttempts > 0 ? ` (${reconnectAttempts})` : ""}...
          </Text>
        )}
        {connectionState === "disconnected" && !isConnected && (
          <Text color="red">disconnected</Text>
        )}
        <Text dimColor>
          mode:<Text bold>{mode}</Text>
        </Text>
        <Text dimColor>
          model:<Text bold>{model}</Text>
        </Text>
        {sessionId && (
          <Text dimColor>
            session:<Text bold>{sessionId.slice(0, 8)}</Text>
          </Text>
        )}
        {agentCount > 0 && (
          <Text dimColor>
            agents:<Text bold color={workingCount > 0 ? "green" : undefined}>
              {workingCount}/{agentCount}
            </Text>
          </Text>
        )}
        {keybindMode === "vim" && (
          <Text dimColor>
            vim:<Text bold color={vimMode === "normal" ? "yellow" : "green"}>
              {vimMode.toUpperCase()}
            </Text>
          </Text>
        )}
        {splitMode && selectedAgent && (
          <Text dimColor>
            split:<Text bold color="cyan">{selectedAgent}</Text>
          </Text>
        )}
      </Box>
      <Box>
        {isStreaming && !hasStreamingContent && (
          <Text color="yellow">thinking...</Text>
        )}
        {hasStreamingContent && (
          <Text color="yellow">streaming...</Text>
        )}
      </Box>
    </Box>
  );
}
