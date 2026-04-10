import React from "react";
import { Box, Text } from "ink";
import {
  computeSkeletonChars,
  textLineWidths,
  type AnimationMode,
} from "../../lib/skeletonAnimation.js";
import { useSharedSkeletonTimer } from "../../hooks/useSkeletonAnimation.js";

interface Props {
  lines?: number;
  maxWidth: number;
  mode?: AnimationMode;
  fillChar?: string;
  elapsedMs?: number;
}

export function SkeletonText({
  lines = 3,
  maxWidth,
  mode = "sweep",
  fillChar,
  elapsedMs: externalElapsed,
}: Props) {
  const timerElapsed = useSharedSkeletonTimer();
  const elapsed = externalElapsed ?? timerElapsed;
  const widths = textLineWidths(lines);

  return (
    <Box flexDirection="column">
      {widths.map((mult, row) => {
        const lineWidth = Math.max(1, Math.floor(maxWidth * mult));
        const chars = computeSkeletonChars(lineWidth, elapsed + row * 120, mode, fillChar);
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
