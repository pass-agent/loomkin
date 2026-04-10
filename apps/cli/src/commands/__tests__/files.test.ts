import { expect, test, vi, beforeEach } from "vitest";
import type { CommandContext } from "../registry.js";

vi.mock("../../lib/api.js", () => ({
  listFiles: vi.fn(),
  readFile: vi.fn(),
  searchFiles: vi.fn(),
  grepFiles: vi.fn(),
  ApiError: class ApiError extends Error {
    constructor(
      public status: number,
      public body: string,
    ) {
      super(`API ${status}: ${body}`);
      this.name = "ApiError";
    }
    get isNotFound() {
      return this.status === 404;
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
import { listFiles, readFile, searchFiles, grepFiles } from "../../lib/api.js";

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

beforeEach(async () => {
  vi.clearAllMocks();
  await import("../files.js");
});

test("files command is registered", () => {
  const result = resolve("/files");
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("files");
});

test.each(["f", "ls"])("alias '%s' resolves to files", (alias) => {
  const result = resolve(`/${alias}`);
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("files");
});

test("lists current directory by default", async () => {
  (listFiles as any).mockResolvedValue({
    path: ".",
    entries: [
      { name: "src", type: "dir", size: "160B", modified: "2026-03-23", is_dir: true },
      { name: "package.json", type: "file", size: "1KB", modified: "2026-03-23", is_dir: false },
    ],
  });

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("", ctx);

  const output = getMessage(ctx);
  expect(output).toContain("src/");
  expect(output).toContain("package.json");
  expect(output).toContain("2 entries");
});

test("lists specific directory", async () => {
  (listFiles as any).mockResolvedValue({
    path: "src",
    entries: [
      { name: "index.ts", type: "file", size: "500B", modified: "2026-03-23", is_dir: false },
    ],
  });

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("src", ctx);

  expect(listFiles).toHaveBeenCalledWith("src");
  expect(getMessage(ctx)).toContain("index.ts");
});

test("shows empty directory message", async () => {
  (listFiles as any).mockResolvedValue({ path: "empty", entries: [] });

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("empty", ctx);

  expect(getMessage(ctx)).toContain("empty");
});

test("search subcommand calls searchFiles", async () => {
  (searchFiles as any).mockResolvedValue({
    pattern: "**/*.ts",
    files: ["src/index.ts", "src/app.ts"],
  });

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("search **/*.ts", ctx);

  expect(searchFiles).toHaveBeenCalledWith("**/*.ts", undefined);
  const output = getMessage(ctx);
  expect(output).toContain("2 file(s)");
  expect(output).toContain("src/index.ts");
});

test("search with no pattern shows usage", async () => {
  const ctx = createMockContext();
  await resolve("/files")!.command.handler("search", ctx);

  expect(getMessage(ctx)).toContain("Usage");
});

test("read subcommand calls readFile", async () => {
  (readFile as any).mockResolvedValue({
    content: "line 1\nline 2\nline 3",
  });

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("read src/index.ts", ctx);

  expect(readFile).toHaveBeenCalledWith("src/index.ts", {
    offset: undefined,
    limit: undefined,
  });
  expect(getMessage(ctx)).toContain("line 1");
});

test("read with offset and limit", async () => {
  (readFile as any).mockResolvedValue({ content: "line 10" });

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("read src/index.ts 10 20", ctx);

  expect(readFile).toHaveBeenCalledWith("src/index.ts", {
    offset: 10,
    limit: 20,
  });
});

test("read with no path shows usage", async () => {
  const ctx = createMockContext();
  await resolve("/files")!.command.handler("read", ctx);

  expect(getMessage(ctx)).toContain("Usage");
});

test("grep subcommand calls grepFiles", async () => {
  (grepFiles as any).mockResolvedValue({
    pattern: "TODO",
    matches: [
      { file: "src/app.ts", line: 5, content: "// TODO: fix this" },
      { file: "src/lib.ts", line: 12, content: "// TODO: refactor" },
    ],
  });

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("grep TODO", ctx);

  expect(grepFiles).toHaveBeenCalledWith("TODO", { glob: undefined });
  const output = getMessage(ctx);
  expect(output).toContain("2 match(es)");
  expect(output).toContain("src/app.ts");
});

test("grep with glob filter", async () => {
  (grepFiles as any).mockResolvedValue({
    pattern: "TODO",
    matches: [],
  });

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("grep TODO *.ex", ctx);

  expect(grepFiles).toHaveBeenCalledWith("TODO", { glob: "*.ex" });
});

test("grep with no pattern shows usage", async () => {
  const ctx = createMockContext();
  await resolve("/files")!.command.handler("grep", ctx);

  expect(getMessage(ctx)).toContain("Usage");
});

test("handles API errors gracefully", async () => {
  (listFiles as any).mockRejectedValue(new Error("network error"));

  const ctx = createMockContext();
  await resolve("/files")!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("File operation failed");
});

test.each(["find", "cat"])("alias '%s' works for subcommands", async (alias) => {
  if (alias === "find") {
    (searchFiles as any).mockResolvedValue({
      pattern: "*.ts",
      files: ["a.ts"],
    });
  } else {
    (readFile as any).mockResolvedValue({ content: "test" });
  }

  const ctx = createMockContext();
  const args = alias === "find" ? "find *.ts" : "cat test.ts";
  await resolve("/files")!.command.handler(args, ctx);

  expect(ctx.addSystemMessage).toHaveBeenCalled();
});
