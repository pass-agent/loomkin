import { expect, test, beforeEach } from "vitest";
import { sessionStore } from "../sessionStore.js";
import type { Message, ToolCall } from "../../lib/types.js";

function makeMessage(overrides: Partial<Message> = {}): Message {
  return {
    id: `msg-${Math.random().toString(36).slice(2)}`,
    role: "user",
    content: "test message",
    tool_calls: null,
    tool_call_id: null,
    token_count: null,
    agent_name: null,
    inserted_at: new Date().toISOString(),
    ...overrides,
  };
}

function makeToolCall(overrides: Partial<ToolCall> = {}): ToolCall {
  return {
    id: `tc-${Math.random().toString(36).slice(2)}`,
    name: "shell",
    arguments: { command: "ls" },
    ...overrides,
  };
}

beforeEach(() => {
  sessionStore.setState({
    sessionId: null,
    messages: [],
    isStreaming: false,
    pendingToolCalls: [],
    scrollOffset: 0,
  });
});

test.each<{ value: string | null; label: string }>([
  { value: "session-1", label: "sets session ID" },
  { value: null, label: "clears session ID" },
])("setSessionId $label", ({ value }) => {
  sessionStore.getState().setSessionId(value);
  expect(sessionStore.getState().sessionId).toBe(value);
});

test("addMessage appends messages in order", () => {
  const msg1 = makeMessage({ content: "first" });
  const msg2 = makeMessage({ content: "second" });
  sessionStore.getState().addMessage(msg1);
  sessionStore.getState().addMessage(msg2);
  const messages = sessionStore.getState().messages;
  expect(messages).toHaveLength(2);
  expect(messages[0].content).toBe("first");
  expect(messages[1].content).toBe("second");
});

test("updateMessage updates only the targeted message", () => {
  const msg1 = makeMessage({ id: "msg-1", content: "keep" });
  const msg2 = makeMessage({ id: "msg-2", content: "change" });
  sessionStore.getState().addMessage(msg1);
  sessionStore.getState().addMessage(msg2);
  sessionStore.getState().updateMessage("msg-2", { content: "changed" });
  expect(sessionStore.getState().messages[0].content).toBe("keep");
  expect(sessionStore.getState().messages[1].content).toBe("changed");
});

test("loadMessages replaces all messages and resets scroll", () => {
  sessionStore.getState().addMessage(makeMessage({ content: "old" }));
  sessionStore.getState().setScrollOffset(5);

  const newMessages = [
    makeMessage({ content: "new-1" }),
    makeMessage({ content: "new-2" }),
  ];
  sessionStore.getState().loadMessages(newMessages);

  expect(sessionStore.getState().messages).toHaveLength(2);
  expect(sessionStore.getState().messages[0].content).toBe("new-1");
  expect(sessionStore.getState().messages[1].content).toBe("new-2");
  expect(sessionStore.getState().scrollOffset).toBe(0);
});

test("loadMessages with empty array clears messages", () => {
  sessionStore.getState().addMessage(makeMessage());
  sessionStore.getState().loadMessages([]);
  expect(sessionStore.getState().messages).toHaveLength(0);
});

test("clearMessages empties messages and resets scroll", () => {
  sessionStore.getState().addMessage(makeMessage());
  sessionStore.getState().addMessage(makeMessage());
  sessionStore.getState().setScrollOffset(5);
  sessionStore.getState().clearMessages();
  expect(sessionStore.getState().messages).toHaveLength(0);
  expect(sessionStore.getState().scrollOffset).toBe(0);
});

test.each([true, false])(
  "setStreaming(%s) updates streaming state",
  (streaming) => {
    sessionStore.getState().setStreaming(streaming);
    expect(sessionStore.getState().isStreaming).toBe(streaming);
  },
);

test("startStreamingMessage creates a placeholder assistant message", () => {
  sessionStore.getState().startStreamingMessage("stream-1");
  const messages = sessionStore.getState().messages;
  expect(messages).toHaveLength(1);
  expect(messages[0].id).toBe("stream-1");
  expect(messages[0].role).toBe("assistant");
  expect(messages[0].content).toBe("");
});

test("appendStreamContent concatenates tokens to existing message", () => {
  sessionStore.getState().startStreamingMessage("stream-1");
  sessionStore.getState().appendStreamContent("stream-1", "Hello");
  sessionStore.getState().appendStreamContent("stream-1", " world");
  expect(sessionStore.getState().messages[0].content).toBe("Hello world");
});

test("appendStreamContent is a no-op for unknown id", () => {
  sessionStore.getState().startStreamingMessage("stream-1");
  sessionStore.getState().appendStreamContent("unknown-id", "token");
  expect(sessionStore.getState().messages[0].content).toBe("");
});

test("pendingToolCalls: add, remove, clear", () => {
  const tc1 = makeToolCall({ id: "tc-1" });
  const tc2 = makeToolCall({ id: "tc-2" });

  sessionStore.getState().addPendingToolCall(tc1);
  sessionStore.getState().addPendingToolCall(tc2);
  expect(sessionStore.getState().pendingToolCalls).toHaveLength(2);

  sessionStore.getState().removePendingToolCall("tc-1");
  expect(sessionStore.getState().pendingToolCalls).toHaveLength(1);
  expect(sessionStore.getState().pendingToolCalls[0].id).toBe("tc-2");

  sessionStore.getState().clearPendingToolCalls();
  expect(sessionStore.getState().pendingToolCalls).toHaveLength(0);
});

test("setScrollOffset updates offset", () => {
  sessionStore.getState().setScrollOffset(10);
  expect(sessionStore.getState().scrollOffset).toBe(10);
});
