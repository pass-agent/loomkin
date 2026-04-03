import React from "react";
import { Box } from "ink";
import { SkeletonText } from "./SkeletonText.js";

interface Props {
  maxWidth?: number;
}

/**
 * Skeleton placeholder for an assistant message during the
 * first-token wait (after sending a message, before any content streams in).
 * Replaces the bare cursor block (█) for a more polished feel.
 */
export function MessageSkeleton({ maxWidth = 60 }: Props) {
  return (
    <Box flexDirection="column">
      <SkeletonText lines={2} maxWidth={maxWidth} mode="sweep" />
    </Box>
  );
}
