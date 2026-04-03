import React from "react";
import { Box, Text } from "ink";
import { computeSkeletonChars, type AnimationMode } from "../../lib/skeletonAnimation.js";
import { useSharedSkeletonTimer } from "../../hooks/useSkeletonAnimation.js";

interface Props {
  width: number;
  height?: number;
  mode?: AnimationMode;
  fillChar?: string;
  elapsedMs?: number;
}

export function SkeletonBlock({
  width,
  height = 1,
  mode = "breathe",
  fillChar,
  elapsedMs: externalElapsed,
}: Props) {
  const timerElapsed = useSharedSkeletonTimer();
  const elapsed = externalElapsed ?? timerElapsed;

  return (
    <Box flexDirection="column">
      {Array.from({ length: height }, (_, row) => {
        const chars = computeSkeletonChars(width, elapsed + row * 100, mode, fillChar);
        return (
          <Text key={row}>
            {chars.map((c, i) => (
              <Text key={i} dimColor={c.dim} bold={c.bold}>
                {c.char}
              </Text>
            ))}
          </Text>
        );
      })}
    </Box>
  );
}
