import React, { createContext, useContext } from "react";
import { useAnimation } from "ink";

const DEFAULT_INTERVAL_MS = 150;

/**
 * Hook that returns a monotonically increasing elapsed-ms counter,
 * ticking at the given interval. All skeleton animation is derived
 * from this single number — no per-component timers needed.
 */
export function useSkeletonAnimation(intervalMs = DEFAULT_INTERVAL_MS): number {
  const { time } = useAnimation({ interval: intervalMs });
  return time;
}

// ── Shared timer context ─────────────────────────────────────────────
// When multiple skeletons are on screen, wrap them in a single
// SkeletonTimerProvider to share one setInterval instead of N.

const SkeletonTimerContext = createContext<number | null>(null);

interface ProviderProps {
  intervalMs?: number;
  children: React.ReactNode;
}

export function SkeletonTimerProvider({
  intervalMs = DEFAULT_INTERVAL_MS,
  children,
}: ProviderProps) {
  const elapsed = useSkeletonAnimation(intervalMs);
  return React.createElement(SkeletonTimerContext.Provider, { value: elapsed }, children);
}

/**
 * Use the shared timer from SkeletonTimerProvider if available,
 * otherwise fall back to a local timer.
 */
export function useSharedSkeletonTimer(intervalMs = DEFAULT_INTERVAL_MS): number {
  const shared = useContext(SkeletonTimerContext);
  const { time } = useAnimation({ interval: intervalMs, isActive: shared === null });
  return shared ?? time;
}
