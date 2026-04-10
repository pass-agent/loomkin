import React, { useEffect, useMemo } from "react";
import { Box, Text, useAnimation } from "ink";
import { useStore } from "zustand";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAgentStore } from "../stores/agentStore.js";

// Spool of thread rotating — the loom is winding up
const WAIT_FRAMES = ["◐", "◓", "◑", "◒"];
// Iris dilating in the dark — something looms
const LOOM_FRAMES = ["◌", "○", "◎", "◉", "●", "◉", "◎", "○"];
// Braille dots circling — tokens rushing through
const STREAM_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const INTERVAL_MS = 160;

function compactName(name: string): string {
  if (name.length <= 24) return name;
  return `${name.slice(0, 23)}…`;
}

function normalizePreview(text: string | undefined): string {
  if (!text) return "";
  return text.replace(/\s+/g, " ").trim();
}

function trimPreview(text: string, max = 42): string {
  if (text.length <= max) return text;
  return `${text.slice(0, max - 1)}…`;
}

function summarizeAgent(agent: {
  name: string;
  currentTool?: string;
  currentTask?: string;
  currentThought?: string;
  lastThought?: string;
}): string {
  if (agent.currentTool) {
    return `${compactName(agent.name)} tool:${trimPreview(agent.currentTool, 24)}`;
  }

  const thought = normalizePreview(agent.currentThought || agent.lastThought);
  if (thought) {
    return `${compactName(agent.name)} thinking:${trimPreview(thought)}`;
  }

  if (agent.currentTask) {
    return `${compactName(agent.name)} ${trimPreview(normalizePreview(agent.currentTask))}`;
  }

  return `${compactName(agent.name)} working`;
}

export function ProcessingStatus() {
  const isStreaming = useStore(useSessionStore, (s) => s.isStreaming);
  const isPendingResponse = useStore(useSessionStore, (s) => s.isPendingResponse);
  const messages = useStore(useSessionStore, (s) => s.messages);
  const agents = useStore(useAgentStore, (s) => s.agents);
  const activeAgents = useMemo(
    () =>
      Array.from(agents.values())
        .filter((agent) => {
          if (agent.status === "working") return true;
          return Boolean(agent.currentTool || agent.currentThought || agent.currentTask);
        })
        .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
        .slice(0, 2),
    [agents],
  );

  const lastMessage = messages[messages.length - 1];
  const hasStreamingContent =
    isStreaming && lastMessage?.role === "assistant" && (lastMessage.content?.length ?? 0) > 0;

  const hasAgentActivity = activeAgents.length > 0;
  const stateKey = hasStreamingContent
    ? "streaming"
    : isStreaming
      ? "looming"
      : isPendingResponse
        ? "waiting"
        : hasAgentActivity
          ? "agents"
          : null;
  const frames =
    stateKey === "streaming"
      ? STREAM_FRAMES
      : stateKey === "looming" || stateKey === "agents"
        ? LOOM_FRAMES
        : WAIT_FRAMES;

  const isActive = Boolean(isPendingResponse || isStreaming || hasAgentActivity);
  const { frame, reset } = useAnimation({ interval: INTERVAL_MS, isActive });

  // Reset to frame 0 on state transition for clean animation handoff
  useEffect(() => {
    if (isActive) reset();
  }, [stateKey]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!isActive) return null;

  const spinner = frames[frame % frames.length];
  const agentSummary = activeAgents.map(summarizeAgent).join("  ·  ");

  return (
    <Box paddingX={1} gap={1} flexShrink={0}>
      <Text color="yellow">{spinner}</Text>
      {stateKey === "waiting" && <Text color="yellow">waiting...</Text>}
      {stateKey === "looming" && <Text color="yellow">looming...</Text>}
      {stateKey === "streaming" && <Text color="yellow">streaming...</Text>}
      {stateKey === "agents" && <Text color="cyan">kin working: {agentSummary}</Text>}
    </Box>
  );
}
