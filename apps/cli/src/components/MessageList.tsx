import React from "react";
import { Box } from "ink";
import { Message } from "./Message.js";
import type { Message as MessageType, ToolCall } from "../lib/types.js";

interface Props {
  messages: MessageType[];
  pendingToolCalls: ToolCall[];
  isStreaming?: boolean;
  maxVisible?: number;
  maxLines?: number;
  scrollOffset?: number;
  agentFilter?: string | null;
  estimatedWidth?: number;
}

function estimateWrappedLines(text: string | null | undefined, width: number): number {
  const wrapWidth = Math.max(20, width);
  const lines = (text ?? "").split("\n");

  return lines.reduce((total, line) => {
    const length = Math.max(1, line.length);
    return total + Math.max(1, Math.ceil(length / wrapWidth));
  }, 0);
}

// Rough line-height estimate for a message (content lines + 1 margin row).
function estimateHeight(msg: MessageType, estimatedWidth = 80): number {
  const margin = 1;
  const contentWidth = Math.max(20, estimatedWidth - 4);

  switch (msg.role) {
    case "system":
      return estimateWrappedLines(msg.content, contentWidth) + margin;
    case "user":
      return 1 + estimateWrappedLines(msg.content, contentWidth) + margin;
    case "tool":
      return 1 + estimateWrappedLines((msg.content ?? "").slice(0, 300), contentWidth) + margin;
    case "assistant": {
      const contentLines = estimateWrappedLines(msg.content, contentWidth);
      const toolLines = (msg.tool_calls?.length ?? 0) * 2;
      return 1 + contentLines + toolLines + margin;
    }
    default:
      return 2;
  }
}

export function MessageList({
  messages,
  pendingToolCalls,
  isStreaming = false,
  maxVisible = 50,
  maxLines,
  scrollOffset = 0,
  agentFilter,
  estimatedWidth = 80,
}: Props) {
  // Filter by agent if specified
  const filtered =
    agentFilter === undefined ? messages : messages.filter((m) => m.agent_name === agentFilter);

  // Show the most recent messages that fit, respecting scroll offset
  const end = scrollOffset > 0 ? -scrollOffset : undefined;
  const recent = filtered.slice(-(maxVisible + scrollOffset), end);

  // If a line budget is set, fill from the bottom (most recent first) so the
  // newest message is always shown in full rather than clipped at the top.
  let visible = recent;
  if (maxLines != null && maxLines > 0) {
    let budget = maxLines;
    const kept: MessageType[] = [];
    for (let i = recent.length - 1; i >= 0; i--) {
      const h = estimateHeight(recent[i], estimatedWidth);
      if (budget - h < 0 && kept.length > 0) break;
      budget -= h;
      kept.unshift(recent[i]);
    }
    visible = kept;
  }

  return (
    <Box flexDirection="column" flexGrow={1} overflow="hidden" justifyContent="flex-end">
      {visible.map((msg, i) => {
        const isLast = i === visible.length - 1;
        const isStreamingMessage = isLast && isStreaming && msg.role === "assistant";

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
