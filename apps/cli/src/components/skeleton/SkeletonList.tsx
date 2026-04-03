import React from "react";
import { Box, Text } from "ink";
import { computeSkeletonChars, type AnimationMode } from "../../lib/skeletonAnimation.js";
import { useSharedSkeletonTimer } from "../../hooks/useSkeletonAnimation.js";

interface Props {
  count?: number;
  itemWidth: number;
  bulletChar?: string;
  mode?: AnimationMode;
  elapsedMs?: number;
}

export function SkeletonList({
  count = 5,
  itemWidth,
  bulletChar = "●",
  mode = "breathe",
  elapsedMs: externalElapsed,
}: Props) {
  const timerElapsed = useSharedSkeletonTimer();
  const elapsed = externalElapsed ?? timerElapsed;

  // Vary item widths for a natural look
  const widthMultipliers = [0.8, 0.65, 0.9, 0.72, 0.85, 0.6, 0.78, 0.95];

  return (
    <Box flexDirection="column" gap={0}>
      {Array.from({ length: count }, (_, i) => {
        const mult = widthMultipliers[i % widthMultipliers.length]!;
        const lineWidth = Math.max(1, Math.floor(itemWidth * mult));
        const chars = computeSkeletonChars(lineWidth, elapsed + i * 200, mode);
        return (
          <Box key={i} gap={1}>
            <Text dimColor>{bulletChar}</Text>
            <Text>
              {chars.map((c, j) => (
                <Text key={j} dimColor={c.dim} bold={c.bold}>
                  {c.char}
                </Text>
              ))}
            </Text>
          </Box>
        );
      })}
    </Box>
  );
}
