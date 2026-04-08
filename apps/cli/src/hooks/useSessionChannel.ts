import { useEffect, useCallback } from "react";
import { useStore } from "zustand";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAppStore } from "../stores/appStore.js";
import { useChannelStore } from "../stores/channelStore.js";
import { isMcpTool, truncateMcpOutput } from "../lib/mcpTruncation.js";
import { shouldExtract, runBackgroundExtraction } from "../lib/sessionExtractor.js";
import { loadAllMemories, formatMemoriesForPrompt } from "../lib/memory.js";
import { runHooks } from "../lib/hooks.js";
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
      // Token usage is tracked in stream_end only to avoid double-counting.
      // new_message events may also carry usage but we ignore them here since
      // the server sends both events for the same LLM turn.
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
      store.ensureStreamingMessage(payload.message_id);
    });

    on("stream_token", (raw) => {
      const payload = raw as { message_id?: string; token: string };
      const store = useSessionStore.getState();
      const streamId = store.ensureStreamingMessage(payload.message_id);
      store.appendStreamContent(streamId, payload.token);
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
      // Fire background session memory extraction if thresholds are met
      if (shouldExtract()) {
        const sessionId = useSessionStore.getState().sessionId;
        if (sessionId) {
          runBackgroundExtraction(sessionId).catch(() => {
            useSessionStore.getState().setExtractionInProgress(false);
          });
        }
      }
    });

    on("tool_call_started", (raw) => {
      const payload = raw as { tool_call: ToolCall };
      const store = useSessionStore.getState();
      const messageId = store.currentStreamingMessageId ?? undefined;
      store.addPendingToolCall({ ...payload.tool_call, messageId });

      // Run PreToolUse hooks asynchronously — deny prevents the tool from proceeding
      const toolUseId = payload.tool_call.id;
      useSessionStore.getState().hookStarted(toolUseId);
      void runHooks("PreToolUse", {
        tool: payload.tool_call.name,
        input: payload.tool_call.arguments,
      }).then((hookOutputs) => {
        useSessionStore.getState().hookCompleted(toolUseId);
        const denied = hookOutputs.find((o) => o.decision === "deny");
        if (denied) {
          useChannelStore.getState().getChannel()?.push("tool_denied", {
            call_id: payload.tool_call.id,
            reason: denied.reason ?? "Denied by hook",
          });
          useSessionStore.getState().removePendingToolCall(payload.tool_call.id);
        }
        const sysMsg = hookOutputs.find((o) => o.systemMessage);
        if (sysMsg?.systemMessage) {
          useSessionStore.getState().addMessage({
            id: `hook-msg-${Date.now()}`,
            role: "system",
            content: sysMsg.systemMessage,
            tool_calls: null,
            tool_call_id: null,
            token_count: null,
            agent_name: null,
            inserted_at: new Date().toISOString(),
          });
        }
      }).catch(() => {
        useSessionStore.getState().hookCompleted(toolUseId);
      });
    });

    on("tool_call_completed", (raw) => {
      const payload = raw as { tool_call: ToolCall };
      const store = useSessionStore.getState();

      // Truncate MCP tool output to prevent context overflow
      if (isMcpTool(payload.tool_call.name ?? "") && payload.tool_call.output != null) {
        const result = truncateMcpOutput(payload.tool_call.output);
        store.addMcpOutputChars(payload.tool_call.output.length);
        if (result.truncated) {
          // Mutate the output in the payload so downstream handlers see the truncated version
          (payload.tool_call as ToolCall).output = result.output;
          store.addMessage({
            id: `mcp-truncated-${Date.now()}`,
            role: "system",
            content: `MCP tool output truncated (${result.removedChars} chars removed)`,
            tool_calls: null,
            tool_call_id: null,
            token_count: null,
            agent_name: null,
            inserted_at: new Date().toISOString(),
          });
        }
      }

      // Track file paths accessed by file/read/write/edit/bash tools
      const toolName = payload.tool_call.name ?? "";
      if (/file|read|write|edit|bash/i.test(toolName)) {
        const args = payload.tool_call.arguments ?? {};
        const filePath =
          (args["path"] as string | undefined) ??
          (args["file_path"] as string | undefined) ??
          (args["command"] as string | undefined);
        if (filePath && typeof filePath === "string") {
          store.trackFilePath(filePath);
        }
      }

      store.removePendingToolCall(payload.tool_call.id);
      store.incrementToolCallsForExtraction();

      // Run PostToolUse hooks (fire-and-forget)
      const postToolUseId = payload.tool_call.id;
      useSessionStore.getState().hookStarted(postToolUseId);
      runHooks("PostToolUse", {
        tool: payload.tool_call.name,
        output: payload.tool_call.output,
      }).then(() => {
        useSessionStore.getState().hookCompleted(postToolUseId);
      }).catch(() => {
        useSessionStore.getState().hookCompleted(postToolUseId);
      });
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

      // Re-inject context (recent files + memories) after compaction if enabled
      const appState = useAppStore.getState();
      if (appState.injectContextAfterCompact) {
        const { recentFilePaths } = store;
        const liveChannel = useChannelStore.getState().getChannel();
        const memories = loadAllMemories();
        const memorySummary = formatMemoriesForPrompt(memories);
        if (liveChannel) {
          liveChannel.push("inject_context", {
            recent_files: recentFilePaths.slice(0, 5),
            memory_summary: memorySummary,
          });
        }
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

      // Auto-compact if enabled and threshold reached
      const appState = useAppStore.getState();
      const now = Date.now();
      const cooldownPassed =
        !appState.lastAutoCompactAt || now - appState.lastAutoCompactAt > 60_000;

      if (
        appState.autoCompact &&
        typeof percent === "number" &&
        percent >= 85 &&
        cooldownPassed
      ) {
        const liveChannel = useChannelStore.getState().getChannel();
        if (liveChannel) {
          liveChannel.push("compact_history", {});
          appState.setLastAutoCompactAt(now);
          store.addMessage({
            id: `auto-compact-${now}`,
            role: "system",
            content: `Auto-compacting conversation (context at ${percent}% — threshold: 85%)`,
            tool_calls: null,
            tool_call_id: null,
            token_count: null,
            agent_name: null,
            inserted_at: new Date().toISOString(),
          });
        }
      }
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

  const setFastModel = useCallback((model: string) => {
    const ch = useChannelStore.getState().getChannel();
    if (!ch) return;
    ch.push("set_fast_model", { model });
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
    setFastModel,
    respondPermission,
    answerQuestion,
    respondApproval,
    respondSpawnGate,
    respondPlan,
  };
}
