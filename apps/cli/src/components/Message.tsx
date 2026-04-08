import React, { useState } from "react";
import { Box, Text, useInput } from "ink";
import { MarkdownText } from "./MarkdownText.js";
import { ToolCallDisplay } from "./ToolCallDisplay.js";
import { GroupedToolDisplay } from "./GroupedToolDisplay.js";
import { MessageSkeleton } from "./skeleton/MessageSkeleton.js";
import type { Message as MessageType, ToolCall, GroupedToolUse } from "../lib/types.js";

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

function ThinkingBlock({ content, isActive = false }: { content: string; isActive?: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const tokenCount = estimateTokens(content);

  useInput(
    (input, key) => {
      if (key.return || input === " ") {
        setExpanded((e) => !e);
      }
    },
    { isActive },
  );

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

  const roleLabel = agent_name || "assistant";

  return (
    <Box flexDirection="column" marginBottom={1}>
      {role === "user" && (
        <Box flexDirection="column">
          <Text color="blue" bold dimColor>
            you
          </Text>
          {(content ?? "").split("\n").map((line, i) => (
            <Text key={i}>{line}</Text>
          ))}
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
            isStreaming && <MessageSkeleton maxWidth={60} />
          )}
          {(() => {
            if (!tool_calls || tool_calls.length === 0) return null;
            const pendingSet = new Set(pendingToolCalls.map((p) => p.id));
            const allInProgress = tool_calls.length >= 2 && tool_calls.every((tc) => pendingSet.has(tc.id));
            if (allInProgress) {
              const grouped: GroupedToolUse[] = tool_calls.map((tc) => ({
                toolUseId: tc.id,
                toolName: tc.renderer?.userFacingName(tc.arguments) || tc.name,
                input: tc.arguments,
                isResolved: false,
                isError: false,
                isInProgress: true,
              }));
              return <GroupedToolDisplay toolUses={grouped} />;
            }
            return tool_calls.map((tc) => (
              <ToolCallDisplay
                key={tc.id}
                toolCall={tc}
                isPending={pendingSet.has(tc.id)}
              />
            ));
          })()}
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
