import React, { useState, useEffect } from "react";
import { Box, Text } from "ink";
import { useStore } from "zustand";
import { useSessionStore } from "../stores/sessionStore.js";

// Spool of thread rotating — the loom is winding up
const WAIT_FRAMES = ["◐", "◓", "◑", "◒"];
// Iris dilating in the dark — something looms
const LOOM_FRAMES = ["◌", "○", "◎", "◉", "●", "◉", "◎", "○"];
// Braille dots circling — tokens rushing through
const STREAM_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const INTERVAL_MS = 160;

export function ProcessingStatus() {
  const isStreaming = useStore(useSessionStore, (s) => s.isStreaming);
  const isPendingResponse = useStore(useSessionStore, (s) => s.isPendingResponse);
  const messages = useStore(useSessionStore, (s) => s.messages);

  const lastMessage = messages[messages.length - 1];
  const hasStreamingContent =
    isStreaming &&
    lastMessage?.role === "assistant" &&
    (lastMessage.content?.length ?? 0) > 0;

  const stateKey = hasStreamingContent ? "streaming" : isStreaming ? "looming" : "waiting";
  const frames =
    stateKey === "streaming" ? STREAM_FRAMES
    : stateKey === "looming" ? LOOM_FRAMES
    : WAIT_FRAMES;

  const [frame, setFrame] = useState(0);

  // Reset to frame 0 on state transition for clean animation handoff
  useEffect(() => {
    setFrame(0);
  }, [stateKey]);

  // Advance spinner while active
  useEffect(() => {
    if (!isPendingResponse && !isStreaming) return;
    const id = setInterval(
      () => setFrame((f) => (f + 1) % frames.length),
      INTERVAL_MS,
    );
    return () => clearInterval(id);
  }, [isPendingResponse, isStreaming, frames.length]);

  if (!isPendingResponse && !isStreaming) return null;

  const spinner = frames[frame] ?? frames[0];

  return (
    <Box paddingX={1} gap={1} flexShrink={0}>
      <Text color="yellow">{spinner}</Text>
      {stateKey === "waiting" && <Text color="yellow">waiting...</Text>}
      {stateKey === "looming" && <Text color="yellow">looming...</Text>}
      {stateKey === "streaming" && <Text color="yellow">streaming...</Text>}
    </Box>
  );
}
