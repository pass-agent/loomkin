import React from "react";
import { Box, Text } from "ink";
import { SkeletonTimerProvider } from "../../hooks/useSkeletonAnimation.js";
import { SkeletonText } from "./SkeletonText.js";

interface Props {
  width: number;
  messageCount?: number;
}

/**
 * Skeleton shown when loading session history (e.g., switching conversations).
 * Renders a list of message-shaped placeholders.
 */
export function SessionLoadingSkeleton({ width, messageCount = 4 }: Props) {
  const contentWidth = Math.min(width - 4, 72);
  const roles = ["user", "assistant", "user", "assistant", "user", "assistant"];

  return (
    <SkeletonTimerProvider>
      <Box flexDirection="column" paddingX={1}>
        {Array.from({ length: messageCount }, (_, i) => {
          const role = roles[i % roles.length]!;
          const lines = role === "user" ? 1 : 2 + (i % 2);
          return (
            <Box key={i} flexDirection="column" marginBottom={1}>
              <Text dimColor bold>{role}</Text>
              <SkeletonText
                lines={lines}
                maxWidth={role === "user" ? Math.floor(contentWidth * 0.5) : contentWidth}
                mode={role === "user" ? "breathe" : "sweep"}
              />
            </Box>
          );
        })}
      </Box>
    </SkeletonTimerProvider>
  );
}
