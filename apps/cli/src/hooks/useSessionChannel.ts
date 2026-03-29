import { useEffect, useCallback } from "react";
import { useStore } from "zustand";
import { useSessionStore } from "../stores/sessionStore.js";
import { useAppStore } from "../stores/appStore.js";
import { joinChannel, leaveChannel } from "../lib/socket.js";
import type { Message, ToolCall, PermissionRequest, AskUserQuestion } from "../lib/types.js";
import type { Channel } from "phoenix";

let currentChannel: Channel | null = null;

export function useSessionChannel() {
  const sessionId = useStore(useSessionStore, (s) => s.sessionId);
  const connectionState = useStore(useAppStore, (s) => s.connectionState);
  const isConnected = connectionState === "connected";
  const messages = useStore(useSessionStore, (s) => s.messages);
  const isStreaming = useStore(useSessionStore, (s) => s.isStreaming);
  const pendingToolCalls = useStore(useSessionStore, (s) => s.pendingToolCalls);
  const pendingPermissions = useStore(useSessionStore, (s) => s.pendingPermissions);
  const pendingQuestions = useStore(useSessionStore, (s) => s.pendingQuestions);

  useEffect(() => {
    if (!sessionId || !isConnected) return;

    const topic = `session:${sessionId}`;
    const channel = joinChannel(topic, {}, (resp) => {
      if (resp.model && typeof resp.model === "string") {
        useAppStore.getState().setModel(resp.model);
      }
    });
    currentChannel = channel;

    channel.on("new_message", (payload: { message: Message }) => {
      const store = useSessionStore.getState();
      // A completed assistant message means the response cycle is done
      if (payload.message.role === "assistant") {
        store.setPendingResponse(false);
        store.setStreaming(false);
      }
      const existing = store.messages.find(
        (m) => m.id === payload.message.id,
      );
      if (existing) {
        store.updateMessage(payload.message.id, payload.message);
      } else {
        store.addMessage(payload.message);
      }
    });

    channel.on("message_updated", (payload: { message: Message }) => {
      useSessionStore
        .getState()
        .updateMessage(payload.message.id, payload.message);
    });

    channel.on(
      "stream_start",
      (payload: { message_id?: string }) => {
        const store = useSessionStore.getState();
        store.setPendingResponse(false);
        store.setStreaming(true);
        if (payload.message_id) {
          store.startStreamingMessage(payload.message_id);
        }
      },
    );

    channel.on(
      "stream_token",
      (payload: { message_id?: string; token: string }) => {
        const store = useSessionStore.getState();
        if (payload.message_id) {
          store.appendStreamContent(payload.message_id, payload.token);
        } else {
          // Streaming without a message_id — append to latest assistant message
          const msgs = store.messages;
          const last = msgs[msgs.length - 1];
          if (last?.role === "assistant") {
            store.appendStreamContent(last.id, payload.token);
          }
        }
      },
    );

    channel.on("stream_end", () => {
      const store = useSessionStore.getState();
      store.setPendingResponse(false);
      store.setStreaming(false);
    });

    channel.on(
      "tool_call_started",
      (payload: { tool_call: ToolCall }) => {
        useSessionStore.getState().addPendingToolCall(payload.tool_call);
      },
    );

    channel.on(
      "tool_call_completed",
      (payload: { tool_call: ToolCall }) => {
        useSessionStore
          .getState()
          .removePendingToolCall(payload.tool_call.id);
      },
    );

    // Permission request from agent needing tool approval
    channel.on(
      "permission_request",
      (payload: PermissionRequest) => {
        useSessionStore.getState().addPendingPermission(payload);
      },
    );

    // Agent asking the user a question
    channel.on(
      "ask_user",
      (payload: AskUserQuestion) => {
        useSessionStore.getState().addPendingQuestion(payload);
      },
    );

    // LLM error — clear pending state so the UI doesn't get stuck
    channel.on("llm_error", (payload: { error: string }) => {
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

    return () => {
      currentChannel = null;
      leaveChannel(topic);
    };
  }, [sessionId, isConnected]);

  const sendMessage = useCallback((content: string, targetAgent?: string) => {
    if (!currentChannel) return;

    const payload: Record<string, string> = { content };
    if (targetAgent) payload.target_agent = targetAgent;

    currentChannel
      .push("send_message", payload)
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
    if (!currentChannel) return;
    currentChannel.push("set_model", { model });
  }, []);

  const respondPermission = useCallback(
    (requestId: string, action: "allow_once" | "allow_always" | "deny") => {
      if (!currentChannel) return;

      currentChannel
        .push("permission_response", { id: requestId, action })
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
      if (!currentChannel) return;

      currentChannel
        .push("ask_user_answer", { question_id: questionId, answer })
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
  };
}
