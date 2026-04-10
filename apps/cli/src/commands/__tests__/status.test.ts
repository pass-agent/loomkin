import { expect, test, vi, beforeEach } from "vitest";
import type { CommandContext } from "../registry.js";

vi.mock("../../lib/api.js", () => ({
  getMe: vi.fn(),
  getSession: vi.fn(),
  listModelProviders: vi.fn(),
  listSessions: vi.fn(),
  ApiError: class ApiError extends Error {
    constructor(
      public status: number,
      public body: string,
    ) {
      super(`API ${status}: ${body}`);
      this.name = "ApiError";
    }
  },
}));

vi.mock("../../lib/constants.js", () => ({
  DEFAULT_SERVER_URL: "https://loom.test",
  DEV_FALLBACK_URL: null,
  DEFAULT_MODE: "code",
  DEFAULT_MODEL: "",
  MODES: ["code", "plan", "chat"],
}));

vi.mock("../../lib/config.js", () => ({
  getConfig: () => ({
    serverUrl: "https://loom.test",
    token: "test-token",
    defaultMode: "code",
    defaultModel: "anthropic:claude-opus-4",
  }),
  isAuthenticated: () => true,
}));

import { resolve } from "../registry.js";
import { getMe, getSession, listModelProviders, listSessions } from "../../lib/api.js";

function createMockContext(
  overrides: Partial<{
    connectionState: string;
    sessionId: string | null;
    errors: Array<{ type: string; message: string; recoverable: boolean }>;
  }> = {},
): CommandContext {
  return {
    appStore: {
      serverUrl: "https://loom.test",
      token: "test-token",
      mode: "code",
      model: "anthropic:claude-opus-4",
      connectionState: overrides.connectionState ?? "connected",
      isConnected: (overrides.connectionState ?? "connected") === "connected",
      reconnectAttempts: 0,
      errors: overrides.errors ?? [],
      setConnectionState: vi.fn(),
      incrementReconnectAttempts: vi.fn(),
      setMode: vi.fn(),
      setModel: vi.fn(),
      setToken: vi.fn(),
      addError: vi.fn(),
      dismissError: vi.fn(),
      clearErrors: vi.fn(),
    },
    sessionStore: {
      sessionId: "sessionId" in overrides ? (overrides.sessionId ?? null) : "abc-123-def",
      messages: [],
      isStreaming: false,
      pendingToolCalls: [],
      pendingPermissions: [],
      pendingQuestions: [],
      scrollOffset: 0,
      setSessionId: vi.fn(),
      addMessage: vi.fn(),
      updateMessage: vi.fn(),
      clearMessages: vi.fn(),
      sendMessage: vi.fn(),
      setStreaming: vi.fn(),
      addPendingToolCall: vi.fn(),
      removePendingToolCall: vi.fn(),
      clearPendingToolCalls: vi.fn(),
      setScrollOffset: vi.fn(),
      loadMessages: vi.fn(),
      startStreamingMessage: vi.fn(),
      appendStreamContent: vi.fn(),
      addPendingPermission: vi.fn(),
      removePendingPermission: vi.fn(),
      addPendingQuestion: vi.fn(),
      removePendingQuestion: vi.fn(),
    },
    addSystemMessage: vi.fn(),
    clearMessages: vi.fn(),
    sendMessage: vi.fn(),
    exit: vi.fn(),
  } as unknown as CommandContext;
}

function getMessage(ctx: CommandContext): string {
  const calls = (ctx.addSystemMessage as ReturnType<typeof vi.fn>).mock.calls;
  return calls.map((c) => c[0]).join("\n");
}

beforeEach(async () => {
  vi.clearAllMocks();
  await import("../status.js");
});

test("status command is registered", () => {
  const result = resolve("/status");
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("status");
});

test("status alias 'st' resolves", () => {
  const result = resolve("/st");
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("status");
});

test.each([
  {
    name: "shows connection state",
    connectionState: "connected",
    expected: "connected",
  },
  {
    name: "shows disconnected state",
    connectionState: "disconnected",
    expected: "disconnected",
  },
  {
    name: "shows reconnecting state",
    connectionState: "reconnecting",
    expected: "reconnecting",
  },
])("$name", async ({ connectionState, expected }) => {
  (getMe as any).mockResolvedValue({
    user: { id: "u1", email: "test@loomkin.dev" },
  });
  (getSession as any).mockResolvedValue({
    session: {
      id: "abc-123-def",
      title: "Test Session",
      status: "active",
      model: "anthropic:claude-opus-4",
      fast_model: null,
      project_path: "/tmp",
      prompt_tokens: 1500,
      completion_tokens: 500,
      cost_usd: 0.05,
      team_id: null,
      inserted_at: "2026-01-01T00:00:00",
      updated_at: "2026-01-01T00:00:00",
    },
  });
  (listModelProviders as any).mockResolvedValue({ providers: [] });
  (listSessions as any).mockResolvedValue({ sessions: [] });

  const ctx = createMockContext({ connectionState });
  const result = resolve("/status");
  await result!.command.handler("", ctx);

  const output = getMessage(ctx);
  expect(output).toContain(expected);
});

test("shows user email", async () => {
  (getMe as any).mockResolvedValue({
    user: { id: "u1", email: "dev@loomkin.dev" },
  });
  (getSession as any).mockResolvedValue({
    session: {
      id: "abc-123-def",
      title: null,
      status: "active",
      model: "anthropic:claude-opus-4",
      fast_model: null,
      project_path: "/tmp",
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: null,
      team_id: null,
      inserted_at: "2026-01-01T00:00:00",
      updated_at: "2026-01-01T00:00:00",
    },
  });
  (listModelProviders as any).mockResolvedValue({ providers: [] });
  (listSessions as any).mockResolvedValue({ sessions: [] });

  const ctx = createMockContext();
  const result = resolve("/status");
  await result!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("dev@loomkin.dev");
});

test("shows provider status", async () => {
  (getMe as any).mockResolvedValue({
    user: { id: "u1", email: "test@loomkin.dev" },
  });
  (getSession as any).mockRejectedValue(new Error("skip"));
  (listModelProviders as any).mockResolvedValue({
    providers: [
      {
        id: "anthropic",
        name: "Anthropic",
        status: { type: "api_key", status: "set" },
        models: [{ label: "Claude", id: "anthropic:claude-opus-4", context: "200k" }],
      },
      {
        id: "openai",
        name: "OpenAI",
        status: { type: "api_key", status: "missing" },
        models: [],
      },
    ],
  });
  (listSessions as any).mockResolvedValue({ sessions: [] });

  const ctx = createMockContext();
  const result = resolve("/status");
  await result!.command.handler("", ctx);

  const output = getMessage(ctx);
  expect(output).toContain("Anthropic");
  expect(output).toContain("OpenAI");
  expect(output).toContain("1 models");
});

test("shows errors when present", async () => {
  (getMe as any).mockResolvedValue({
    user: { id: "u1", email: "test@loomkin.dev" },
  });
  (getSession as any).mockRejectedValue(new Error("skip"));
  (listModelProviders as any).mockResolvedValue({ providers: [] });
  (listSessions as any).mockResolvedValue({ sessions: [] });

  const ctx = createMockContext({
    errors: [{ type: "network", message: "Connection timeout", recoverable: true }],
  });
  const result = resolve("/status");
  await result!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("Connection timeout");
});

test("shows no active session when sessionId is null", async () => {
  (getMe as any).mockResolvedValue({
    user: { id: "u1", email: "test@loomkin.dev" },
  });
  (listModelProviders as any).mockResolvedValue({ providers: [] });
  (listSessions as any).mockResolvedValue({ sessions: [] });

  const ctx = createMockContext({ sessionId: null });
  const result = resolve("/status");
  await result!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("No active session");
});

test.each([
  { tokens: 1500000, expected: "1.5M" },
  { tokens: 2500, expected: "2.5k" },
  { tokens: 500, expected: "500" },
])("formats $tokens tokens as $expected", async ({ tokens, expected }) => {
  (getMe as any).mockResolvedValue({
    user: { id: "u1", email: "test@loomkin.dev" },
  });
  (getSession as any).mockResolvedValue({
    session: {
      id: "abc-123-def",
      title: "Test",
      status: "active",
      model: "anthropic:claude-opus-4",
      fast_model: null,
      project_path: "/tmp",
      prompt_tokens: tokens,
      completion_tokens: 0,
      cost_usd: null,
      team_id: null,
      inserted_at: "2026-01-01T00:00:00",
      updated_at: "2026-01-01T00:00:00",
    },
  });
  (listModelProviders as any).mockResolvedValue({ providers: [] });
  (listSessions as any).mockResolvedValue({ sessions: [] });

  const ctx = createMockContext();
  const result = resolve("/status");
  await result!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain(expected);
});

test("handles API failure gracefully", async () => {
  (getMe as any).mockRejectedValue(new Error("network error"));
  (getSession as any).mockRejectedValue(new Error("network error"));
  (listModelProviders as any).mockRejectedValue(new Error("network error"));
  (listSessions as any).mockRejectedValue(new Error("network error"));

  const ctx = createMockContext();
  const result = resolve("/status");
  await result!.command.handler("", ctx);

  const output = getMessage(ctx);
  // Should still produce output even when APIs fail
  expect(output).toContain("Loomkin Status");
  expect(output).toContain("Unable to fetch");
});
