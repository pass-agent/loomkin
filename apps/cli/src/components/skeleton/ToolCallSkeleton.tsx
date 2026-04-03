import React from "react";
import { Box } from "ink";
import { SkeletonBlock } from "./SkeletonBlock.js";

interface Props {
  width?: number;
}

/**
 * Shimmer bar shown below the existing ink-spinner for pending tool calls.
 * Adds visual weight to indicate active computation.
 */
export function ToolCallSkeleton({ width = 30 }: Props) {
  return (
    <Box marginLeft={2} marginTop={0}>
      <SkeletonBlock width={width} height={1} mode="shimmer" fillChar="░" />
    </Box>
  );
}
