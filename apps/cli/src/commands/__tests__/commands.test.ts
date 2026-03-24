import { expect, test, vi, beforeEach } from "vitest";
import type { CommandContext } from "../registry.js";
import type { AppState } from "../../stores/appStore.js";
import type { SessionState } from "../../stores/sessionStore.js";

vi.mock("../../lib/api.js", () => ({
  listSessions: vi.fn().mockResolvedValue({ sessions: [] }),
  getSessionMessages: vi.fn().mockResolvedValue({ messages: [] }),
  ApiError: class ApiError extends Error {
    constructor(public status: number, public body: string) {
      super(`API ${status}: ${body}`);
    }
  },
}));

function createMockContext(
  overrides: { mode?: string; model?: string; sessionId?: string | null } = {},
): CommandContext {
  return {
    appStore: {
      mode: overrides.mode ?? "code",
      model: overrides.model ?? "anthropic:claude-opus-4",
      setMode: vi.fn(),
      setModel: vi.fn(),
    } as unknown as AppState,
    sessionStore: {
      sessionId: overrides.sessionId ?? "test-session-123",
      setSessionId: vi.fn(),
      clearMessages: vi.fn(),
      sendMessage: vi.fn(),
      loadMessages: vi.fn(),
      clearPendingToolCalls: vi.fn(),
      clearPendingPermissions: vi.fn(),
      clearPendingQuestions: vi.fn(),
    } as unknown as SessionState,
    addSystemMessage: vi.fn(),
    sendMessage: vi.fn(),
    clearMessages: vi.fn(),
    exit: vi.fn(),
  };
}

function getMessage(ctx: CommandContext, callIndex = 0): string {
  return (ctx.addSystemMessage as ReturnType<typeof vi.fn>).mock.calls[callIndex][0] as string;
}

let resolve: typeof import("../registry.js")["resolve"];

beforeEach(async () => {
  ({ resolve } = await import("../registry.js"));
  await import("../help.js");
  await import("../clear.js");
  await import("../mode.js");
  await import("../model.js");
  await import("../quit.js");
  await import("../compact.js");
  await import("../session.js");
  await import("../mcp.js");
});

test.each([
  {
    command: "/help",
    args: "",
    assertion: (ctx: CommandContext) => {
      expect(ctx.addSystemMessage).toHaveBeenCalledOnce();
      expect(getMessage(ctx)).toContain("/help");
      expect(getMessage(ctx)).toContain("/quit");
    },
  },
  {
    command: "/clear",
    args: "",
    assertion: (ctx: CommandContext) => {
      expect(ctx.clearMessages).toHaveBeenCalledOnce();
      expect(ctx.addSystemMessage).toHaveBeenCalledWith("Messages cleared.");
    },
  },
  {
    command: "/quit",
    args: "",
    assertion: (ctx: CommandContext) => {
      expect(ctx.exit).toHaveBeenCalledOnce();
    },
  },
  {
    command: "/compact",
    args: "",
    assertion: (ctx: CommandContext) => {
      expect(ctx.addSystemMessage).toHaveBeenCalledOnce();
    },
  },
  // mcp is now async and tested separately in mcp.test.ts
])("$command handler behaves correctly", ({ command, args, assertion }) => {
  const ctx = createMockContext();
  resolve(command)!.command.handler(args, ctx);
  assertion(ctx);
});

test.each([
  { args: "", mode: "code", label: "shows current mode when no args" },
])("/mode $label", ({ args, mode }) => {
  const ctx = createMockContext({ mode });
  resolve("/mode")!.command.handler(args, ctx);
  expect(getMessage(ctx)).toContain(mode);
});

test.each([
  { args: "plan", label: "switches to plan" },
  { args: "chat", label: "switches to chat" },
  { args: "code", label: "switches to code" },
])("/mode $label", ({ args }) => {
  const ctx = createMockContext();
  resolve("/mode")!.command.handler(args, ctx);
  expect(ctx.appStore.setMode).toHaveBeenCalledWith(args);
});

test("/mode rejects invalid mode", () => {
  const ctx = createMockContext();
  resolve("/mode")!.command.handler("invalid", ctx);
  expect(ctx.appStore.setMode).not.toHaveBeenCalled();
  expect(getMessage(ctx)).toContain("Unknown mode");
});

test.each([
  { args: "", model: "anthropic:claude-opus-4", label: "shows current model when no args" },
])("/model $label", ({ args, model }) => {
  const ctx = createMockContext({ model });
  resolve("/model")!.command.handler(args, ctx);
  expect(getMessage(ctx)).toContain(model);
});

test("/model switches to requested model", () => {
  const ctx = createMockContext();
  resolve("/model")!.command.handler("claude-sonnet-4", ctx);
  expect(ctx.appStore.setModel).toHaveBeenCalledWith("claude-sonnet-4");
});

test.each([
  { sessionId: "abc-123", args: "", expected: "abc-123", label: "shows current session" },
  { sessionId: null as string | null, args: "", expected: "No active session", label: "shows no session when null" },
])("/session $label", ({ sessionId, args, expected }) => {
  const ctx = createMockContext({ sessionId });
  if (sessionId === null) {
    (ctx.sessionStore as unknown as Record<string, unknown>).sessionId = null;
  }
  resolve("/session")!.command.handler(args, ctx);
  expect(getMessage(ctx)).toContain(expected);
});

test("/session switches to requested session", async () => {
  const ctx = createMockContext();
  await resolve("/session")!.command.handler("new-session-id", ctx);
  expect(ctx.sessionStore.setSessionId).toHaveBeenCalledWith("new-session-id");
});
