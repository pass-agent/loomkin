import React from "react";
import { Box, Text } from "ink";
import Spinner from "ink-spinner";
import type { ToolCall } from "../lib/types.js";

interface Props {
  toolCall: ToolCall;
  isPending?: boolean;
}

export function ToolCallDisplay({ toolCall, isPending }: Props) {
  const argsPreview = JSON.stringify(toolCall.arguments).slice(0, 80);

  return (
    <Box flexDirection="column" marginLeft={2}>
      <Box gap={1}>
        {isPending && (
          <Text color="yellow">
            <Spinner type="dots" />
          </Text>
        )}
        <Text color="cyan" bold>
          {toolCall.name}
        </Text>
        <Text dimColor>{argsPreview}</Text>
      </Box>
      {toolCall.output && (
        <Box marginLeft={2}>
          <Text dimColor wrap="truncate-end">
            {toolCall.output.slice(0, 200)}
          </Text>
        </Box>
      )}
    </Box>
  );
}
