import { useEffect, useCallback } from "react";
import { useStore } from "zustand";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAppStore } from "../stores/appStore.js";
import { useChannelStore } from "../stores/channelStore.js";
import type { Message, ToolCall, PermissionRequest, AskUserQuestion, PlanMessage } from "../lib/types.js";

/**
 * Subscribes to session-level events on the shared Phoenix channel.
 * The channel lifecycle is owned by useChannelLifecycle — this hook
 * only attaches/detaches its event handlers.
 */
export function useSessionChannel() {
  const channel = useStore(useChannelStore, (s) => s.channel);
  const messages = useStore(useSessionStore, (s) => s.messages);
  const isStreaming = useStore(useSessionStore, (s) => s.isStreaming);
  const pendingToolCalls = useStore(useSessionStore, (s) => s.pendingToolCalls);
  const pendingPermissions = useStore(useSessionStore, (s) => s.pendingPermissions);
  const pendingQuestions = useStore(useSessionStore, (s) => s.pendingQuestions);

  useEffect(() => {
    if (!channel) return;

    const events: string[] = [];

    const ch = channel; // non-null binding for closures

    function on(event: string, handler: (payload: Record<string, unknown>) => void) {
      ch.on(event, handler);
      events.push(event);
    }

    on("new_message", (raw) => {
      const payload = raw as {
        message: Message;
        usage?: { input_tokens?: number; output_tokens?: number; model?: string };
      };
      const store = useSessionStore.getState();
      if (payload.message.role === "assistant") {
        store.setPendingResponse(false);
        store.setStreaming(false);
      }
      const existing = store.messages.find((m) => m.id === payload.message.id);
      if (existing) {
        store.updateMessage(payload.message.id, payload.message);
      } else {
        store.addMessage(payload.message);
      }
      // Track token usage from message event if provided by server
      if (payload.usage) {
        const inputTokens = payload.usage.input_tokens ?? 0;
        const outputTokens = payload.usage.output_tokens ?? 0;
        const model = payload.usage.model ?? useAppStore.getState().model ?? "";
        if (inputTokens > 0 || outputTokens > 0) {
          store.trackTokenUsage(inputTokens, outputTokens, model);
        }
      }
    });

    on("message_updated", (raw) => {
      const payload = raw as { message: Message };
      useSessionStore.getState().updateMessage(payload.message.id, payload.message);
    });

    on("stream_start", (raw) => {
      const payload = raw as { message_id?: string };
      const store = useSessionStore.getState();
      store.setPendingResponse(false);
      store.setStreaming(true);
      if (payload.message_id) {
        store.startStreamingMessage(payload.message_id);
      }
    });

    on("stream_token", (raw) => {
      const payload = raw as { message_id?: string; token: string };
      const store = useSessionStore.getState();
      if (payload.message_id) {
        store.appendStreamContent(payload.message_id, payload.token);
      } else {
        const msgs = store.messages;
        const last = msgs[msgs.length - 1];
        if (last?.role === "assistant") {
          store.appendStreamContent(last.id, payload.token);
        }
      }
    });

    on("stream_end", (raw) => {
      const payload = raw as {
        usage?: { input_tokens?: number; output_tokens?: number; model?: string };
      };
      const store = useSessionStore.getState();
      store.setPendingResponse(false);
      store.setStreaming(false);
      // Track token usage from stream_end if server sends it here
      if (payload?.usage) {
        const inputTokens = payload.usage.input_tokens ?? 0;
        const outputTokens = payload.usage.output_tokens ?? 0;
        const model = payload.usage.model ?? useAppStore.getState().model ?? "";
        if (inputTokens > 0 || outputTokens > 0) {
          store.trackTokenUsage(inputTokens, outputTokens, model);
        }
      }
    });

    on("tool_call_started", (raw) => {
      const payload = raw as { tool_call: ToolCall };
      useSessionStore.getState().addPendingToolCall(payload.tool_call);
    });

    on("tool_call_completed", (raw) => {
      const payload = raw as { tool_call: ToolCall };
      useSessionStore.getState().removePendingToolCall(payload.tool_call.id);
    });

    on("permission_request", (raw) => {
      const payload = raw as unknown as PermissionRequest;
      useSessionStore.getState().addPendingPermission(payload);
    });

    on("ask_user", (raw) => {
      const payload = raw as unknown as AskUserQuestion;
      useSessionStore.getState().addPendingQuestion(payload);
    });

    on("llm_error", (raw) => {
      const payload = raw as { error: string };
      const store = useSessionStore.getState();
      store.setPendingResponse(false);
      store.setStreaming(false);
      store.addMessage({
        id: `llm-error-${Date.now()}`,
        role: "system",
        content: `Error: ${payload.error}`,
        tool_calls: null,
        tool_call_id: null,
        token_count: null,
        agent_name: null,
        inserted_at: new Date().toISOString(),
      });
    });

    on("compaction_complete", (raw) => {
      const payload = raw as { context_budget_percent?: number; summary?: string };
      const store = useSessionStore.getState();
      // Add a visual separator to the message list
      store.addMessage({
        id: `compaction-${Date.now()}`,
        role: "system",
        content: "─── Conversation compacted ───",
        tool_calls: null,
        tool_call_id: null,
        token_count: null,
        agent_name: null,
        inserted_at: new Date().toISOString(),
      });
      // Update context budget if server reports remaining capacity
      if (typeof payload.context_budget_percent === "number") {
        store.setContextBudgetPercent(payload.context_budget_percent);
      }
    });

    on("plan_proposal", (raw) => {
      const payload = raw as unknown as PlanMessage;
      useSessionStore.getState().addPendingPlan(payload);
    });

    on("context_warning", (raw) => {
      const payload = raw as { context_budget_percent?: number; message?: string };
      const store = useSessionStore.getState();
      const percent = payload.context_budget_percent;
      if (typeof percent === "number") {
        store.setContextBudgetPercent(percent);
      }
      const msg = payload.message ?? `Context window is getting full${typeof percent === "number" ? ` (${percent}% remaining)` : ""}. Consider using /compact.`;
      store.addMessage({
        id: `ctx-warning-${Date.now()}`,
        role: "system",
        content: msg,
        tool_calls: null,
        tool_call_id: null,
        token_count: null,
        agent_name: null,
        inserted_at: new Date().toISOString(),
      });
    });

    return () => {
      for (const event of new Set(events)) {
        ch.off(event);
      }
    };
  }, [channel]);

  // Callbacks use channelStore.getState().getChannel() for always-live reference
  const sendMessage = useCallback((content: string, targetAgent?: string) => {
    const ch = useChannelStore.getState().getChannel();
    if (!ch) return;

    const payload: Record<string, string> = { content };
    if (targetAgent) payload.target_agent = targetAgent;

    ch.push("send_message", payload)
      .receive("ok", () => {
        useSessionStore.getState().setPendingResponse(true);
      })
      .receive("error", (resp: Record<string, unknown>) => {
        useSessionStore.getState().setPendingResponse(false);
        useAppStore.getState().addError({
          type: "api",
          message: `Failed to send message: ${JSON.stringify(resp)}`,
          recoverable: false,
        });
        useSessionStore.getState().addMessage({
          id: `error-${Date.now()}`,
          role: "system",
          content: "Failed to send message. Please try again.",
          tool_calls: null,
          tool_call_id: null,
          token_count: null,
          agent_name: null,
          inserted_at: new Date().toISOString(),
        });
      });
  }, []);

  const setModel = useCallback((model: string) => {
    const ch = useChannelStore.getState().getChannel();
    if (!ch) return;
    ch.push("set_model", { model });
  }, []);

  const respondPermission = useCallback(
    (requestId: string, action: "allow_once" | "allow_always" | "deny") => {
      const ch = useChannelStore.getState().getChannel();
      if (!ch) return;

      ch.push("permission_response", { id: requestId, action })
        .receive("ok", () => {
          useSessionStore.getState().removePendingPermission(requestId);
        })
        .receive("error", () => {
          useSessionStore.getState().removePendingPermission(requestId);
          useSessionStore.getState().addMessage({
            id: `error-perm-${Date.now()}`,
            role: "system",
            content: "Permission response failed to reach server.",
            tool_calls: null,
            tool_call_id: null,
            token_count: null,
            agent_name: null,
            inserted_at: new Date().toISOString(),
          });
        });
    },
    [],
  );

  const answerQuestion = useCallback(
    (questionId: string, answer: string) => {
      const ch = useChannelStore.getState().getChannel();
      if (!ch) return;

      ch.push("ask_user_answer", { question_id: questionId, answer })
        .receive("ok", () => {
          useSessionStore.getState().removePendingQuestion(questionId);
        })
        .receive("error", () => {
          useSessionStore.getState().removePendingQuestion(questionId);
          useSessionStore.getState().addMessage({
            id: `error-answer-${Date.now()}`,
            role: "system",
            content: "Answer failed to send. The agent may time out.",
            tool_calls: null,
            tool_call_id: null,
            token_count: null,
            agent_name: null,
            inserted_at: new Date().toISOString(),
          });
        });
    },
    [],
  );

  const respondApproval = useCallback(
    (gateId: string, outcome: "approved" | "denied", context?: string, reason?: string) => {
      const ch = useChannelStore.getState().getChannel();
      if (!ch) return;

      ch.push("approval_response", { gate_id: gateId, outcome, context, reason })
        .receive("ok", () => {
          useSessionStore.getState().removePendingApproval(gateId);
        })
        .receive("error", () => {
          useSessionStore.getState().removePendingApproval(gateId);
          useSessionStore.getState().addMessage({
            id: `error-approval-${Date.now()}`,
            role: "system",
            content: "Approval response failed — gate may have expired.",
            tool_calls: null,
            tool_call_id: null,
            token_count: null,
            agent_name: null,
            inserted_at: new Date().toISOString(),
          });
        });
    },
    [],
  );

  const respondSpawnGate = useCallback(
    (gateId: string, outcome: "approved" | "denied", reason?: string) => {
      const ch = useChannelStore.getState().getChannel();
      if (!ch) return;

      ch.push("spawn_gate_response", { gate_id: gateId, outcome, reason })
        .receive("ok", () => {
          useSessionStore.getState().removePendingSpawnGate(gateId);
        })
        .receive("error", () => {
          useSessionStore.getState().removePendingSpawnGate(gateId);
          useSessionStore.getState().addMessage({
            id: `error-spawn-gate-${Date.now()}`,
            role: "system",
            content: "Spawn gate response failed — gate may have expired.",
            tool_calls: null,
            tool_call_id: null,
            token_count: null,
            agent_name: null,
            inserted_at: new Date().toISOString(),
          });
        });
    },
    [],
  );

  const respondPlan = useCallback(
    (planId: string, outcome: "approved" | "rejected", reason?: string) => {
      const ch = useChannelStore.getState().getChannel();
      if (!ch) return;

      const event = outcome === "approved" ? "plan_approved" : "plan_rejected";
      ch.push(event, { plan_id: planId, ...(reason ? { reason } : {}) })
        .receive("ok", () => {
          useSessionStore.getState().removePendingPlan(planId);
        })
        .receive("error", () => {
          useSessionStore.getState().removePendingPlan(planId);
          useSessionStore.getState().addMessage({
            id: `error-plan-${Date.now()}`,
            role: "system",
            content: "Plan response failed — plan may have expired.",
            tool_calls: null,
            tool_call_id: null,
            token_count: null,
            agent_name: null,
            inserted_at: new Date().toISOString(),
          });
        });
    },
    [],
  );

  return {
    messages,
    isStreaming,
    pendingToolCalls,
    pendingPermissions,
    pendingQuestions,
    sendMessage,
    setModel,
    respondPermission,
    answerQuestion,
    respondApproval,
    respondSpawnGate,
    respondPlan,
  };
}
