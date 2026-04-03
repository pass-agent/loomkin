import { expect, test, vi, beforeEach } from "vitest";
import type { CommandContext } from "../registry.js";

vi.mock("../../lib/api.js", () => ({
  getDecisions: vi.fn(),
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
    lastSessionId: null,
  }),
  isAuthenticated: () => true,
}));

import { resolve } from "../registry.js";
import { getDecisions } from "../../lib/api.js";

function createMockContext(): CommandContext {
  return {
    appStore: {} as CommandContext["appStore"],
    sessionStore: {} as CommandContext["sessionStore"],
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

const mockNodes = [
  {
    id: "abc-123-def-456",
    node_type: "goal",
    title: "Ship CLI TUI",
    description: "Build a terminal interface for loomkin",
    status: "active",
    confidence: 85,
    agent_name: "architect",
    session_id: "sess-1",
    inserted_at: "2026-03-23T10:00:00",
  },
  {
    id: "def-456-ghi-789",
    node_type: "decision",
    title: "Use React Ink",
    description: null,
    status: "resolved",
    confidence: null,
    agent_name: null,
    session_id: "sess-1",
    inserted_at: "2026-03-23T09:00:00",
  },
];

beforeEach(async () => {
  vi.clearAllMocks();
  await import("../logs.js");
});

test("logs command is registered", () => {
  const result = resolve("/logs");
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("logs");
});

test.each(["log", "decisions"])("alias '%s' resolves to logs", (alias) => {
  const result = resolve(`/${alias}`);
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("logs");
});

test("shows recent decisions by default", async () => {
  (getDecisions as any).mockResolvedValue({
    type: "recent_decisions",
    nodes: mockNodes,
  });

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("", ctx);

  const output = getMessage(ctx);
  expect(output).toContain("Recent Decisions");
  expect(output).toContain("Ship CLI TUI");
  expect(output).toContain("Use React Ink");
});

test("goals subcommand fetches active goals", async () => {
  (getDecisions as any).mockResolvedValue({
    type: "active_goals",
    nodes: [mockNodes[0]],
  });

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("goals", ctx);

  expect(getDecisions).toHaveBeenCalledWith({ type: "active_goals" });
  expect(getMessage(ctx)).toContain("Active Goals");
  expect(getMessage(ctx)).toContain("Ship CLI TUI");
});

test("pulse subcommand shows health score", async () => {
  (getDecisions as any).mockResolvedValue({
    type: "pulse",
    summary: "Project is healthy and on track.",
    health_score: 82,
  });

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("pulse", ctx);

  expect(getDecisions).toHaveBeenCalledWith({ type: "pulse" });
  const output = getMessage(ctx);
  expect(output).toContain("Pulse");
  expect(output).toContain("82/100");
  expect(output).toContain("on track");
});

test("search subcommand searches by term", async () => {
  (getDecisions as any).mockResolvedValue({
    type: "search",
    query: "ink",
    nodes: [mockNodes[1]],
  });

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("search ink", ctx);

  expect(getDecisions).toHaveBeenCalledWith({ type: "search", q: "ink" });
  expect(getMessage(ctx)).toContain("Use React Ink");
});

test("search with no query shows usage", async () => {
  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("search", ctx);

  expect(getMessage(ctx)).toContain("Usage");
});

test("shows empty state for no decisions", async () => {
  (getDecisions as any).mockResolvedValue({
    type: "recent_decisions",
    nodes: [],
  });

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("No decisions logged");
});

test("shows empty state for no goals", async () => {
  (getDecisions as any).mockResolvedValue({
    type: "active_goals",
    nodes: [],
  });

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("goals", ctx);

  expect(getMessage(ctx)).toContain("No active goals");
});

test("handles API error gracefully", async () => {
  (getDecisions as any).mockRejectedValue(new Error("network error"));

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("Failed to fetch decisions");
});

test.each([
  { node_type: "goal", icon: "🎯" },
  { node_type: "decision", icon: "⚖️" },
  { node_type: "action", icon: "⚡" },
  { node_type: "outcome", icon: "✅" },
  { node_type: "observation", icon: "👁" },
])("node type '$node_type' shows icon '$icon'", async ({ node_type, icon }) => {
  (getDecisions as any).mockResolvedValue({
    type: "recent_decisions",
    nodes: [{ ...mockNodes[0], node_type }],
  });

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain(icon);
});

test("shows confidence and agent name when present", async () => {
  (getDecisions as any).mockResolvedValue({
    type: "recent_decisions",
    nodes: [mockNodes[0]],
  });

  const ctx = createMockContext();
  await resolve("/logs")!.command.handler("", ctx);

  const output = getMessage(ctx);
  expect(output).toContain("85%");
  expect(output).toContain("@architect");
});
