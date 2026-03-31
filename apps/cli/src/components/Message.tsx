import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import { MarkdownText } from "./MarkdownText.js";
import { ToolCallDisplay } from "./ToolCallDisplay.js";
import type { Message as MessageType, ToolCall } from "../lib/types.js";

interface Props {
  message: MessageType;
  pendingToolCalls?: ToolCall[];
  isStreaming?: boolean;
}

/** Rough token estimate: 1 token ≈ 4 chars */
function estimateTokens(text: string): string {
  const tokens = Math.round(text.length / 4);
  if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}k`;
  return String(tokens);
}

function ThinkingBlock({ content }: { content: string }) {
  const [expanded, setExpanded] = useState(false);
  const tokenCount = estimateTokens(content);

  useInput((input, key) => {
    if (key.return || input === " ") {
      setExpanded((e) => !e);
    }
  });

  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text dimColor>
        {expanded ? "▼" : "▶"}{" "}
        <Text italic>Thinking ({tokenCount} tokens)</Text>
      </Text>
      {expanded && (
        <Box marginLeft={2} flexDirection="column">
          {content.split("\n").map((line, i) => (
            <Text key={i} dimColor italic>
              {line}
            </Text>
          ))}
        </Box>
      )}
    </Box>
  );
}

export function Message({
  message,
  pendingToolCalls = [],
  isStreaming = false,
}: Props) {
  const { role, content, tool_calls, agent_name } = message;

  // Handle thinking role (server sends thinking content as a special message)
  if (role === ("thinking" as MessageType["role"])) {
    return (
      <Box flexDirection="column" marginBottom={1}>
        <ThinkingBlock content={content ?? ""} />
      </Box>
    );
  }

  const roleLabel = agent_name ? `${role}:${agent_name}` : role;

  return (
    <Box flexDirection="column" marginBottom={1}>
      {role === "user" && (
        <Box>
          <Text color="blue" bold>
            {">"}{" "}
          </Text>
          <Text>{content}</Text>
        </Box>
      )}

      {role === "assistant" && (
        <Box flexDirection="column">
          <Text color="green" bold dimColor>
            {roleLabel}
          </Text>
          {content ? (
            <MarkdownText
              content={isStreaming ? `${content}\u2588` : content}
            />
          ) : (
            isStreaming && (
              <Text color="yellow" dimColor>
                {"\u2588"}
              </Text>
            )
          )}
          {tool_calls?.map((tc) => (
            <ToolCallDisplay
              key={tc.id}
              toolCall={tc}
              isPending={pendingToolCalls.some((p) => p.id === tc.id)}
            />
          ))}
        </Box>
      )}

      {role === "system" && (
        <Box flexDirection="column">
          {(content ?? "").split("\n").map((line, i) => (
            <Text key={i} italic dimColor>
              {line}
            </Text>
          ))}
        </Box>
      )}

      {role === "tool" && (
        <Box flexDirection="column" marginLeft={2}>
          <Text color="cyan" dimColor>
            tool result
          </Text>
          {content && (
            <Text dimColor wrap="truncate-end">
              {content.slice(0, 300)}
            </Text>
          )}
        </Box>
      )}
    </Box>
  );
}
