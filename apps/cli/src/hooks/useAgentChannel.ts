import { useEffect } from "react";
import { useStore } from "zustand";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAppStore } from "../stores/appStore.js";
import { useAgentStore } from "../stores/agentStore.js";
import { joinChannel } from "../lib/socket.js";
import type { Channel } from "phoenix";

import type { Message } from "../lib/types.js";

let _agentChannel: Channel | null = null;
let notifyCounter = 0;

function notify(content: string) {
  const msg: Message = {
    id: `notify-${++notifyCounter}`,
    role: "system",
    content,
    tool_calls: null,
    tool_call_id: null,
    token_count: null,
    agent_name: null,
    inserted_at: new Date().toISOString(),
  };
  useSessionStore.getState().addMessage(msg);
}

/**
 * Subscribes to agent-related events on the session channel.
 * Updates the agent store with real-time status, tool use, and task info.
 *
 * Note: Agent events are received on the same `session:<id>` channel
 * as message events — the backend forwards agent.** signals there.
 * This hook piggybacks on the existing channel connection.
 */
export function useAgentChannel() {
  const sessionId = useStore(useSessionStore, (s) => s.sessionId);
  const connectionState = useStore(useAppStore, (s) => s.connectionState);
  const isConnected = connectionState === "connected";
  const agentsMap = useStore(useAgentStore, (s) => s.agents);

  useEffect(() => {
    if (!sessionId || !isConnected) return;

    // Join the same session channel — events come through it
    const topic = `session:${sessionId}`;
    const channel = joinChannel(topic);
    _agentChannel = channel;

    channel.on("agent_status", (payload: { agent_name: string; status: string }) => {
      useAgentStore.getState().upsertAgent(payload.agent_name, {
        status: payload.status,
      });
      if (payload.status === "done" || payload.status === "completed") {
        notify(`✓ ${payload.agent_name} finished`);
      }
    });

    channel.on(
      "agent_role_changed",
      (payload: { agent_name: string; new_role: string }) => {
        useAgentStore.getState().upsertAgent(payload.agent_name, {
          role: payload.new_role,
        });
      },
    );

    channel.on(
      "agent_tool_executing",
      (payload: { agent_name: string; tool_name: string }) => {
        useAgentStore.getState().upsertAgent(payload.agent_name, {
          currentTool: payload.tool_name,
          status: "working",
        });
      },
    );

    channel.on(
      "agent_tool_complete",
      (payload: { agent_name: string; tool_name: string }) => {
        useAgentStore.getState().upsertAgent(payload.agent_name, {
          currentTool: undefined,
        });
      },
    );

    channel.on(
      "agent_error",
      (payload: { agent_name: string; error: string }) => {
        useAgentStore.getState().upsertAgent(payload.agent_name, {
          status: "error",
          lastError: payload.error,
        });
        notify(`⚠ ${payload.agent_name}: ${payload.error}`);
      },
    );

    channel.on(
      "agent_usage",
      (payload: {
        agent_name: string;
        tokens_used?: number;
        cost_usd?: number;
      }) => {
        useAgentStore.getState().upsertAgent(payload.agent_name, {
          tokensUsed: payload.tokens_used,
          costUsd: payload.cost_usd,
        });
      },
    );

    channel.on(
      "agent_spawned",
      (payload: { agent_name: string; role: string; team_id: string }) => {
        useAgentStore.getState().upsertAgent(payload.agent_name, {
          role: payload.role,
          teamId: payload.team_id,
          status: "idle",
        });
        notify(`🤖 Agent ${payload.agent_name} (${payload.role}) joined the team`);
      },
    );

    // --- Collaboration events ---

    channel.on(
      "peer_message",
      (payload: { from: string; to: string; content: string }) => {
        notify(`💬 ${payload.from} → ${payload.to}: ${payload.content}`);
      },
    );

    channel.on(
      "conversation_started",
      (payload: { topic: string; participants: string[] }) => {
        const who = payload.participants.join(", ");
        notify(`🗣 Conversation started: ${payload.topic} (${who})`);
      },
    );

    channel.on(
      "conversation_ended",
      (payload: { topic: string; outcome: string }) => {
        notify(`🗣 Conversation ended: ${payload.topic} → ${payload.outcome ?? "no outcome"}`);
      },
    );

    channel.on(
      "debate_response",
      (payload: { from: string; position: string; reasoning: string }) => {
        notify(`⚔ ${payload.from} argues: ${payload.position}`);
      },
    );

    channel.on(
      "vote_response",
      (payload: { from: string; vote: string; reason: string }) => {
        notify(`🗳 ${payload.from} votes: ${payload.vote}${payload.reason ? ` — ${payload.reason}` : ""}`);
      },
    );

    channel.on("team_dissolved", () => {
      useAgentStore.getState().clearAgents();
      notify("Team dissolved");
    });

    channel.on(
      "team_task_update",
      (payload: {
        type: string;
        agent_name?: string;
        task?: string;
        status?: string;
      }) => {
        if (payload.agent_name && payload.task) {
          useAgentStore.getState().upsertAgent(payload.agent_name, {
            currentTask: payload.task,
          });
        }
      },
    );

    return () => {
      _agentChannel = null;
      // Don't leaveChannel here — useSessionChannel owns the channel lifecycle
    };
  }, [sessionId, isConnected]);

  return { agents: Array.from(agentsMap.values()) };
}
