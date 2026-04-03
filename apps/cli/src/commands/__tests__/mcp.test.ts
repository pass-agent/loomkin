import { expect, test, vi, beforeEach } from "vitest";
import type { CommandContext } from "../registry.js";
import type { McpStatus } from "../../lib/types.js";

vi.mock("../../lib/api.js", () => ({
  getMcpStatus: vi.fn(),
  refreshMcp: vi.fn(),
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
import { getMcpStatus, refreshMcp } from "../../lib/api.js";

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

const mockStatus: McpStatus = {
  server: {
    enabled: true,
    tools: [
      { name: "file_read", module: "Loomkin.Tools.FileRead" },
      { name: "shell", module: "Loomkin.Tools.Shell" },
    ],
  },
  clients: [
    {
      name: "tidewave",
      transport: { type: "stdio", command: "mix tidewave.server" },
      status: "connected",
      tool_count: 5,
    },
    {
      name: "hexdocs",
      transport: { type: "http", url: "http://localhost:3001/sse" },
      status: "error: :not_connected",
      tool_count: 0,
    },
  ],
};

beforeEach(async () => {
  vi.clearAllMocks();
  await import("../mcp.js");
});

test("mcp command is registered", () => {
  const result = resolve("/mcp");
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("mcp");
});

test.each([
  {
    name: "overview shows server status",
    args: "",
    expected: ["MCP", "Server", "enabled", "2 tools exposed"],
  },
  {
    name: "overview shows connected clients",
    args: "",
    expected: ["tidewave", "5 tools", "hexdocs"],
  },
  {
    name: "tools subcommand shows server tools",
    args: "tools",
    expected: ["MCP Tools", "file_read", "shell", "Loomkin.Tools.FileRead"],
  },
  {
    name: "tools subcommand shows client tool counts",
    args: "tools",
    expected: ["tidewave", "5 tools available", "hexdocs", "no tools discovered"],
  },
  {
    name: "server subcommand shows published tools",
    args: "server",
    expected: ["MCP Server", "enabled", "file_read", "shell"],
  },
])("$name", async ({ args, expected }) => {
  (getMcpStatus as any).mockResolvedValue(mockStatus);

  const ctx = createMockContext();
  await resolve("/mcp")!.command.handler(args, ctx);

  const output = getMessage(ctx);
  for (const str of expected) {
    expect(output).toContain(str);
  }
});

test("overview shows config hint when no clients", async () => {
  (getMcpStatus as any).mockResolvedValue({
    server: { enabled: false, tools: [] },
    clients: [],
  });

  const ctx = createMockContext();
  await resolve("/mcp")!.command.handler("", ctx);

  const output = getMessage(ctx);
  expect(output).toContain("No MCP servers connected");
  expect(output).toContain(".loomkin.toml");
});

test("server subcommand shows disabled hint", async () => {
  (getMcpStatus as any).mockResolvedValue({
    server: { enabled: false, tools: [] },
    clients: [],
  });

  const ctx = createMockContext();
  await resolve("/mcp")!.command.handler("server", ctx);

  const output = getMessage(ctx);
  expect(output).toContain("disabled");
  expect(output).toContain("server_enabled = true");
});

test("refresh calls API and shows success", async () => {
  (refreshMcp as any).mockResolvedValue({
    message: "refresh requested for all endpoints",
  });

  const ctx = createMockContext();
  await resolve("/mcp")!.command.handler("refresh", ctx);

  expect(refreshMcp).toHaveBeenCalledWith(undefined);
  expect(getMessage(ctx)).toContain("refresh requested");
});

test("refresh with name calls API for specific endpoint", async () => {
  (refreshMcp as any).mockResolvedValue({
    message: "refresh requested",
  });

  const ctx = createMockContext();
  await resolve("/mcp")!.command.handler("refresh tidewave", ctx);

  expect(refreshMcp).toHaveBeenCalledWith("tidewave");
});

test("handles API failure gracefully", async () => {
  (getMcpStatus as any).mockRejectedValue(new Error("network error"));

  const ctx = createMockContext();
  await resolve("/mcp")!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("Failed to fetch MCP status");
});

test("handles refresh failure gracefully", async () => {
  (refreshMcp as any).mockRejectedValue(new Error("network error"));

  const ctx = createMockContext();
  await resolve("/mcp")!.command.handler("refresh", ctx);

  expect(getMessage(ctx)).toContain("Refresh failed");
});

test.each([
  { status: "connected", expected: "●" },
  { status: "error: :not_connected", expected: "●" },
])("client with status '$status' shows status dot", async ({ status }) => {
  (getMcpStatus as any).mockResolvedValue({
    server: { enabled: false, tools: [] },
    clients: [
      {
        name: "test-server",
        transport: { type: "http", url: "http://localhost:3000" },
        status,
        tool_count: 0,
      },
    ],
  });

  const ctx = createMockContext();
  await resolve("/mcp")!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("test-server");
});
