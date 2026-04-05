import React from "react";
import { Box, Text } from "ink";
import { SkeletonText } from "./SkeletonText.js";

interface Props {
  width: number;
}

/**
 * Skeleton shown during initial WebSocket connection.
 * Only renders message-area placeholders — the real InputArea,
 * ProcessingStatus, and StatusBar are always rendered by App.
 */
export function ConnectionSkeleton({ width }: Props) {
  const contentWidth = Math.min(width - 4, 72);

  return (
    <Box
      flexDirection="column"
      flexGrow={1}
      overflow="hidden"
      paddingX={1}
      justifyContent="flex-end"
    >
      <Box flexDirection="column" marginBottom={1}>
        <Text dimColor bold>assistant</Text>
        <SkeletonText lines={3} maxWidth={contentWidth} mode="sweep" />
      </Box>

      <Box flexDirection="column" marginBottom={1}>
        <Text dimColor bold>assistant</Text>
        <SkeletonText lines={2} maxWidth={contentWidth} mode="sweep" />
      </Box>
    </Box>
  );
}
