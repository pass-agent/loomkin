import React from "react";
import { Box, Text } from "ink";
import { useStore } from "zustand";
import { MessageList } from "./MessageList.js";
import { usePaneStore } from "../stores/paneStore.js";
import { useSessionStore } from "../stores/sessionStore.js";
import type { Message, ToolCall } from "../lib/types.js";

interface Props {
  messages: Message[];
  pendingToolCalls: ToolCall[];
  isStreaming?: boolean;
}

export function SplitPaneLayout({
  messages,
  pendingToolCalls,
  isStreaming = false,
}: Props) {
  const focusedPane = useStore(usePaneStore, (s) => s.focusedPane);
  const selectedAgent = useStore(usePaneStore, (s) => s.selectedAgent);
  const rightScrollOffset = useStore(usePaneStore, (s) => s.rightScrollOffset);
  const leftScrollOffset = useStore(useSessionStore, (s) => s.scrollOffset);

  const leftFocused = focusedPane === "left";
  const rightFocused = focusedPane === "right";

  return (
    <Box flexDirection="row" flexGrow={1}>
      <Box
        flexDirection="column"
        width="50%"
        borderStyle={leftFocused ? "double" : "single"}
        borderColor={leftFocused ? "blue" : "gray"}
      >
        <Box paddingX={1}>
          <Text bold color={leftFocused ? "blue" : "gray"}>
            Main
          </Text>
        </Box>
        <MessageList
          messages={messages}
          pendingToolCalls={pendingToolCalls}
          isStreaming={isStreaming}
          agentFilter={null}
          scrollOffset={leftScrollOffset}
        />
      </Box>
      <Box
        flexDirection="column"
        width="50%"
        borderStyle={rightFocused ? "double" : "single"}
        borderColor={rightFocused ? "blue" : "gray"}
      >
        <Box paddingX={1}>
          <Text bold color={rightFocused ? "blue" : "gray"}>
            {selectedAgent ?? "No agent"}
          </Text>
        </Box>
        <MessageList
          messages={messages}
          pendingToolCalls={pendingToolCalls}
          isStreaming={isStreaming}
          agentFilter={selectedAgent}
          scrollOffset={rightScrollOffset}
        />
      </Box>
    </Box>
  );
}
