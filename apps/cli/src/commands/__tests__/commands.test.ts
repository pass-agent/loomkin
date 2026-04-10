import { expect, test, vi, beforeEach } from "vitest";
import type { CommandContext } from "../registry.js";
import type { AppState } from "../../stores/appStore.js";
import type { SessionState } from "../../stores/sessionStore.js";

vi.mock("../../lib/api.js", () => ({
  listSessions: vi.fn().mockResolvedValue({ sessions: [] }),
  getSession: vi.fn().mockResolvedValue({
    session: {
      id: "abc-123",
      title: "Test",
      model: "anthropic:claude-opus-4",
      prompt_tokens: 0,
      completion_tokens: 0,
      status: "active",
      fast_model: null,
      project_path: "/tmp",
      cost_usd: null,
      team_id: null,
      inserted_at: "",
      updated_at: "",
    },
  }),
  getSessionMessages: vi.fn().mockResolvedValue({ messages: [] }),
  createSession: vi.fn().mockResolvedValue({ session: { id: "new-session" } }),
  updateSession: vi.fn().mockResolvedValue({ session: {} }),
  archiveSession: vi.fn().mockResolvedValue({}),
  listModelProviders: vi.fn().mockResolvedValue({
    providers: [
      {
        id: "anthropic",
        name: "Anthropic",
        status: { type: "api_key", status: "set" },
        models: [
          { id: "anthropic:claude-opus-4", label: "Claude Opus 4", context: "200K" },
          { id: "claude-sonnet-4", label: "Claude Sonnet 4", context: "200K" },
        ],
      },
    ],
  }),
  getMcpStatus: vi.fn().mockResolvedValue({ servers: [] }),
  refreshMcp: vi.fn().mockResolvedValue({ servers: [] }),
  ApiError: class ApiError extends Error {
    constructor(
      public status: number,
      public body: string,
    ) {
      super(`API ${status}: ${body}`);
    }
  },
}));

vi.mock("@clack/prompts", () => ({
  select: vi.fn().mockResolvedValue("anthropic:claude-opus-4"),
  isCancel: vi.fn().mockReturnValue(false),
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
    showListPicker: vi.fn(),
  };
}

function getMessage(ctx: CommandContext, callIndex = 0): string {
  return (ctx.addSystemMessage as ReturnType<typeof vi.fn>).mock.calls[callIndex][0] as string;
}

let resolve: (typeof import("../registry.js"))["resolve"];

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

test("/mode shows list picker when no args", () => {
  const ctx = createMockContext({ mode: "code" });
  resolve("/mode")!.command.handler("", ctx);
  expect(ctx.showListPicker).toHaveBeenCalledOnce();
  expect(ctx.addSystemMessage).not.toHaveBeenCalled();
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
])("/model $label", async ({ args, model }) => {
  const ctx = createMockContext({ model });
  await resolve("/model")!.command.handler(args, ctx);
  expect(getMessage(ctx)).toContain(model);
});

test("/model switches to requested model", async () => {
  const ctx = createMockContext();
  await resolve("/model")!.command.handler("claude-sonnet-4", ctx);
  expect(ctx.appStore.setModel).toHaveBeenCalledWith("claude-sonnet-4");
});

test.each([
  { sessionId: "abc-123", args: "", expected: "abc-123", label: "shows current session" },
  {
    sessionId: null as string | null,
    args: "",
    expected: "No active session",
    label: "shows no session when null",
  },
])("/session $label", async ({ sessionId, args, expected }) => {
  const ctx = createMockContext({ sessionId });
  if (sessionId === null) {
    (ctx.sessionStore as unknown as Record<string, unknown>).sessionId = null;
  }
  await resolve("/session")!.command.handler(args, ctx);
  expect(getMessage(ctx)).toContain(expected);
});

test("/session switches to requested session", async () => {
  const ctx = createMockContext();
  await resolve("/session")!.command.handler("new-session-id", ctx);
  expect(ctx.sessionStore.setSessionId).toHaveBeenCalledWith("new-session-id");
});
