import React from "react";
import { Box, Text } from "ink";
import { SkeletonTimerProvider } from "../../hooks/useSkeletonAnimation.js";
import { SkeletonText } from "./SkeletonText.js";
import { SkeletonBlock } from "./SkeletonBlock.js";

interface Props {
  width: number;
  height: number;
}

/**
 * Full-screen skeleton shown during initial WebSocket connection.
 * Mimics the layout the user will see: message area + input area.
 */
export function ConnectionSkeleton({ width, height }: Props) {
  const contentWidth = Math.min(width - 4, 72);

  return (
    <SkeletonTimerProvider>
      <Box
        flexDirection="column"
        height={height}
        paddingX={1}
        justifyContent="flex-end"
      >
        {/* Simulated previous messages */}
        <Box flexDirection="column" marginBottom={1}>
          <Text dimColor bold>assistant</Text>
          <SkeletonText lines={3} maxWidth={contentWidth} mode="sweep" />
        </Box>

        <Box flexDirection="column" marginBottom={1}>
          <Text dimColor bold>assistant</Text>
          <SkeletonText lines={2} maxWidth={contentWidth} mode="sweep" />
        </Box>

        {/* Simulated input area */}
        <Box borderStyle="round" borderColor="gray" paddingX={1}>
          <Text dimColor>{">"} </Text>
          <SkeletonBlock width={Math.min(20, contentWidth)} height={1} mode="breathe" fillChar="▒" />
        </Box>
      </Box>
    </SkeletonTimerProvider>
  );
}
