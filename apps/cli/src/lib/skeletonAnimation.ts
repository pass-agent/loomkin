/**
 * Pure animation functions for skeleton UI components.
 * Inspired by https://github.com/jharsono/tui-skeleton
 *
 * All functions are stateless — they compute visual state purely from
 * elapsed milliseconds, making them deterministic and easy to test.
 */

export type AnimationMode = "breathe" | "sweep" | "shimmer" | "noise";

export interface SkeletonChar {
  char: string;
  dim: boolean;
  bold: boolean;
}

const BRAILLE_CHARS = ["⠁", "⠂", "⠄", "⡀", "⠈", "⠐", "⠠", "⢀", "⣀", "⣤", "⣶", "⣿"];
const DEFAULT_FILL = "░";

/**
 * Compute an array of styled characters for a single skeleton row.
 *
 * @param width    Number of characters in the row
 * @param elapsedMs  Monotonically increasing milliseconds from the shared timer
 * @param mode     Animation mode
 * @param fillChar Override the default fill character
 */
export function computeSkeletonChars(
  width: number,
  elapsedMs: number,
  mode: AnimationMode,
  fillChar: string = DEFAULT_FILL,
): SkeletonChar[] {
  switch (mode) {
    case "breathe":
      return breathe(width, elapsedMs, fillChar);
    case "sweep":
      return sweep(width, elapsedMs, fillChar);
    case "shimmer":
      return shimmer(width, elapsedMs, fillChar);
    case "noise":
      return noise(width, elapsedMs);
  }
}

/** Pulsing dim on/off — the whole row breathes together. */
function breathe(width: number, elapsedMs: number, fillChar: string): SkeletonChar[] {
  // 1200ms cycle: 600ms dim, 600ms normal
  const phase = (elapsedMs % 1200) / 1200;
  const dim = phase < 0.5;
  return Array.from({ length: width }, () => ({ char: fillChar, dim, bold: false }));
}

/** A bold highlight sweeps left-to-right across the row. */
function sweep(width: number, elapsedMs: number, fillChar: string): SkeletonChar[] {
  if (width === 0) return [];
  // Complete sweep every 1500ms
  const sweepPos = Math.floor(((elapsedMs % 1500) / 1500) * (width + 4)) - 2;
  return Array.from({ length: width }, (_, i) => {
    const dist = Math.abs(i - sweepPos);
    if (dist <= 1) return { char: "▓", dim: false, bold: true };
    if (dist <= 3) return { char: "▒", dim: false, bold: false };
    return { char: fillChar, dim: true, bold: false };
  });
}

/** Three brightness levels cycle across characters with offset. */
function shimmer(width: number, elapsedMs: number, fillChar: string): SkeletonChar[] {
  // 900ms cycle, offset by column position
  return Array.from({ length: width }, (_, i) => {
    const phase = ((elapsedMs + i * 80) % 900) / 900;
    if (phase < 0.33) return { char: fillChar, dim: true, bold: false };
    if (phase < 0.66) return { char: fillChar, dim: false, bold: false };
    return { char: fillChar, dim: false, bold: true };
  });
}

/** Random braille characters change each tick — "computing" effect. */
function noise(width: number, elapsedMs: number): SkeletonChar[] {
  // Use elapsed time as a seed for pseudo-random selection.
  // Not cryptographic — just visually varied.
  const tick = Math.floor(elapsedMs / 150);
  return Array.from({ length: width }, (_, i) => {
    const idx = (tick * 7 + i * 13 + i * i * 3) % BRAILLE_CHARS.length;
    return { char: BRAILLE_CHARS[idx]!, dim: false, bold: false };
  });
}

/**
 * Generate deterministic line-width multipliers for SkeletonText.
 * Produces a natural-looking paragraph shape where the last line is shortest.
 */
export function textLineWidths(lineCount: number): number[] {
  const patterns = [1.0, 0.92, 0.85, 0.78, 0.95, 0.88, 0.7, 0.6];
  return Array.from({ length: lineCount }, (_, i) => {
    if (i === lineCount - 1) return 0.45 + (i % 3) * 0.1; // Last line always short
    return patterns[i % patterns.length]!;
  });
}
