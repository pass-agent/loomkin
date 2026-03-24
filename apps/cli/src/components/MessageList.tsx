import React from "react";
import { Box } from "ink";
import { Message } from "./Message.js";
import type { Message as MessageType, ToolCall } from "../lib/types.js";

interface Props {
  messages: MessageType[];
  pendingToolCalls: ToolCall[];
  isStreaming?: boolean;
  maxVisible?: number;
  scrollOffset?: number;
  agentFilter?: string | null;
}

export function MessageList({
  messages,
  pendingToolCalls,
  isStreaming = false,
  maxVisible = 50,
  scrollOffset = 0,
  agentFilter,
}: Props) {
  // Filter by agent if specified
  const filtered =
    agentFilter === undefined
      ? messages
      : messages.filter((m) => m.agent_name === agentFilter);

  // Show the most recent messages that fit, respecting scroll offset
  const end = scrollOffset > 0 ? -scrollOffset : undefined;
  const visible = filtered.slice(-(maxVisible + scrollOffset), end);

  return (
    <Box flexDirection="column" flexGrow={1}>
      {visible.map((msg, i) => {
        const isLast = i === visible.length - 1;
        const isStreamingMessage =
          isLast && isStreaming && msg.role === "assistant";

        return (
          <Message
            key={msg.id}
            message={msg}
            pendingToolCalls={pendingToolCalls}
            isStreaming={isStreamingMessage}
          />
        );
      })}
    </Box>
  );
}
