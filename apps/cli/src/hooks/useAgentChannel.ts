import { useEffect, useRef } from "react";
import { useStore } from "zustand";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAgentStore } from "../stores/agentStore.js";
import { useConversationStore } from "../stores/conversationStore.js";
import { useChannelStore } from "../stores/channelStore.js";
import {
  getAgentCostsForSession,
  setAgentCostForSession,
} from "../lib/config.js";
import { usePaneStore } from "../stores/paneStore.js";
import { runHooks } from "../lib/hooks.js";

import type { ConversationInfo, Message } from "../lib/types.js";

function makeNotifyMessage(content: string, counter: { current: number }): Message {
  return {
    id: `notify-${++counter.current}`,
    role: "system",
    content,
    tool_calls: null,
    tool_call_id: null,
    token_count: null,
    agent_name: null,
    inserted_at: new Date().toISOString(),
  };
}

/**
 * Subscribes to agent-related events on the shared Phoenix channel.
 * The channel lifecycle is owned by useChannelLifecycle — this hook
 * only attaches/detaches its event handlers.
 */
export function useAgentChannel() {
  const channel = useStore(useChannelStore, (s) => s.channel);
  const agentsMap = useStore(useAgentStore, (s) => s.agents);
  const notifyCounter = useRef(0);

  // Restore persisted costs for the current session on channel connect
  useEffect(() => {
    if (!channel) return;
    const topic = useChannelStore.getState().topic ?? "";
    const sessionId = topic.startsWith("session:") ? topic.slice(8) : null;
    if (!sessionId) return;

    const savedCosts = getAgentCostsForSession(sessionId);
    for (const [agentName, entry] of Object.entries(savedCosts)) {
      useAgentStore.getState().upsertAgent(agentName, {
        costUsd: entry.costUsd,
        tokensUsed: entry.tokensUsed,
      });
    }
  }, [channel]);

  useEffect(() => {
    if (!channel) return;

    const ch = channel; // non-null binding for closures
    const events: string[] = [];

    function notify(content: string) {
      useSessionStore.getState().addMessage(makeNotifyMessage(content, notifyCounter));
    }

    function on<T>(event: string, handler: (payload: T) => void) {
      ch.on(event, handler as (payload: Record<string, unknown>) => void);
      events.push(event);
    }

    // --- Agent events ---

    on<{ agent_name: string; status: string; pause_queued?: boolean }>("agent_status", (payload) => {
      useAgentStore.getState().upsertAgent(payload.agent_name, {
        status: payload.status,
        pauseQueued: payload.pause_queued,
      });
      if (payload.status === "done" || payload.status === "completed") {
        notify(`✓ ${payload.agent_name} finished`);
      }
      if (payload.status === "paused") {
        notify(`⏸ ${payload.agent_name} paused`);
      }
    });

    on<{ agent_name: string; new_role: string }>("agent_role_changed", (payload) => {
      useAgentStore.getState().upsertAgent(payload.agent_name, {
        role: payload.new_role,
      });
    });

    on<{ agent_name: string; tool_name: string }>("agent_tool_executing", (payload) => {
      useAgentStore.getState().upsertAgent(payload.agent_name, {
        currentTool: payload.tool_name,
        status: "working",
      });
    });

    on<{ agent_name: string; tool_name: string }>("agent_tool_complete", (payload) => {
      useAgentStore.getState().upsertAgent(payload.agent_name, {
        currentTool: undefined,
      });
    });

    on<{ agent_name: string; error: string }>("agent_error", (payload) => {
      useAgentStore.getState().upsertAgent(payload.agent_name, {
        status: "error",
        lastError: payload.error,
      });
      notify(`⚠ ${payload.agent_name}: ${payload.error}`);
    });

    on<{ agent_name: string; tokens_used?: number; cost_usd?: number }>(
      "agent_usage",
      (payload) => {
        useAgentStore.getState().upsertAgent(payload.agent_name, {
          tokensUsed: payload.tokens_used,
          costUsd: payload.cost_usd,
        });

        // Persist to config keyed by session
        const topic = useChannelStore.getState().topic ?? "";
        const sessionId = topic.startsWith("session:") ? topic.slice(8) : null;
        if (sessionId && payload.cost_usd != null && payload.tokens_used != null) {
          setAgentCostForSession(
            sessionId,
            payload.agent_name,
            payload.cost_usd,
            payload.tokens_used,
          );
        }
      },
    );

    on<{ agent_name: string; role: string; team_id: string; worktree_path?: string }>("agent_spawned", (payload) => {
      useAgentStore.getState().upsertAgent(payload.agent_name, {
        role: payload.role,
        teamId: payload.team_id,
        status: "idle",
        ...(payload.worktree_path ? { worktreePath: payload.worktree_path } : {}),
      });
      notify(`🤖 Agent ${payload.agent_name} (${payload.role}) joined the team`);

      // Run SubagentStart hooks (fire-and-forget)
      runHooks("SubagentStart", {
        agent_name: payload.agent_name,
        role: payload.role,
      }).catch(() => {});
    });

    // --- Collaboration events ---

    on<{ from: string; to: string; content: string }>("peer_message", (payload) => {
      notify(`💬 ${payload.from} → ${payload.to}: ${payload.content}`);
    });

    on<{ conversation_id: string; topic: string; participants: string[]; strategy?: string; team_id: string }>(
      "conversation_started",
      (payload) => {
        useConversationStore.getState().startConversation(payload);
        // Auto-open split pane to show the conversation feed
        const pane = usePaneStore.getState();
        if (!pane.splitMode) {
          pane.toggleSplitMode();
        }
        const who = payload.participants.join(", ");
        notify(`🗣 Conversation started: ${payload.topic} (${who})`);
      },
    );

    on<{ conversation_id: string; speaker: string; content: string; round: number; team_id: string }>(
      "conversation_turn",
      (payload) => {
        useConversationStore.getState().addTurn({
          conversation_id: payload.conversation_id,
          speaker: payload.speaker,
          content: payload.content,
          round: payload.round,
          type: "speech",
          timestamp: new Date().toISOString(),
        });
      },
    );

    on<{ conversation_id: string; agent_name: string; reaction_type: string; brief: string; team_id: string }>(
      "conversation_reaction",
      (payload) => {
        useConversationStore.getState().addReaction(payload);
      },
    );

    on<{ conversation_id: string; agent_name: string; reason?: string; team_id: string }>(
      "conversation_yield",
      (payload) => {
        useConversationStore.getState().addYield(payload);
      },
    );

    on<{ conversation_id: string; round: number; team_id: string }>(
      "conversation_round_started",
      (payload) => {
        useConversationStore.getState().advanceRound(payload.conversation_id, payload.round);
      },
    );

    on<{ conversation_id: string; round: number; team_id: string }>(
      "conversation_round_complete",
      () => {
        // Informational — next round_started will advance
      },
    );

    on<{ conversation_id: string; team_id: string }>("conversation_summarizing", (payload) => {
      useConversationStore.getState().setSummarizing(payload.conversation_id);
      notify(`📝 Conversation summarizing...`);
    });

    on<{ conversation_id?: string; topic: string; outcome: string; summary?: unknown; team_id: string }>(
      "conversation_ended",
      (payload) => {
        if (payload.conversation_id) {
          useConversationStore.getState().endConversation({
            conversation_id: payload.conversation_id,
            outcome: payload.outcome,
            summary: payload.summary as ConversationInfo["summary"],
          });
        }
        notify(`🗣 Conversation ended: ${payload.topic} → ${payload.outcome ?? "complete"}`);
      },
    );

    on<{ conversation_id: string; tokens_used: number; max_tokens: number; team_id: string }>(
      "conversation_budget_warning",
      (payload) => {
        notify(`⚠ Conversation approaching token limit (${payload.tokens_used}/${payload.max_tokens})`);
      },
    );

    on<{ from: string; position: string; reasoning: string }>("debate_response", (payload) => {
      notify(`⚔ ${payload.from} argues: ${payload.position}`);
    });

    on<{ from: string; vote: string; reason: string }>("vote_response", (payload) => {
      notify(`🗳 ${payload.from} votes: ${payload.vote}${payload.reason ? ` — ${payload.reason}` : ""}`);
    });

    on<Record<string, never>>("team_dissolved", () => {
      useAgentStore.getState().clearAgents();
      notify("Team dissolved");
    });

    on<{ type: string; agent_name?: string; task?: string; status?: string }>(
      "team_task_update",
      (payload) => {
        if (payload.agent_name && payload.task) {
          useAgentStore.getState().upsertAgent(payload.agent_name, {
            currentTask: payload.task,
          });
        }
      },
    );

    // --- Approval gate events ---

    on<{ gate_id: string; agent_name: string; question: string; timeout_ms: number; team_id: string }>(
      "approval_requested",
      (payload) => {
        useSessionStore.getState().addPendingApproval({
          ...payload,
          received_at: Date.now(),
        });
        notify(`🔒 ${payload.agent_name} requests approval: ${payload.question}`);
      },
    );

    on<{ gate_id: string; agent_name: string; outcome: string; team_id: string }>(
      "approval_resolved",
      (payload) => {
        useSessionStore.getState().removePendingApproval(payload.gate_id);
      },
    );

    on<{ gate_id: string; agent_name: string; team_name: string; roles: Array<{ role: string; name?: string }>; estimated_cost: number; purpose: string | null; timeout_ms: number; limit_warning: string | null; team_id: string }>(
      "spawn_gate_requested",
      (payload) => {
        useSessionStore.getState().addPendingSpawnGate({
          ...payload,
          received_at: Date.now(),
        });
        const roleNames = payload.roles.map((r) => r.role).join(", ");
        notify(`🔒 ${payload.agent_name} wants to spawn: ${roleNames} ($${payload.estimated_cost.toFixed(4)})`);
      },
    );

    on<{ gate_id: string; agent_name: string; outcome: string; team_id: string }>(
      "spawn_gate_resolved",
      (payload) => {
        useSessionStore.getState().removePendingSpawnGate(payload.gate_id);
      },
    );

    return () => {
      for (const event of new Set(events)) {
        ch.off(event);
      }
    };
  }, [channel]);

  return { agents: Array.from(agentsMap.values()) };
}
