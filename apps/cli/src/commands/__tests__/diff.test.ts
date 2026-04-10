import { expect, test, vi, beforeEach } from "vitest";
import type { CommandContext } from "../registry.js";

vi.mock("../../lib/api.js", () => ({
  getDiff: vi.fn(),
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
import { getDiff } from "../../lib/api.js";
import { colorizeDiff, parseDiffStats } from "../diff.js";

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

const sampleDiff = `diff --git a/src/app.ts b/src/app.ts
index abc1234..def5678 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -10,3 +10,4 @@ export function main() {
   const x = 1;
-  const y = 2;
+  const y = 3;
+  const z = 4;
`;

beforeEach(async () => {
  vi.clearAllMocks();
  await import("../diff.js");
});

test("diff command is registered", () => {
  const result = resolve("/diff");
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("diff");
});

test("alias 'd' resolves to diff", () => {
  const result = resolve("/d");
  expect(result).not.toBeNull();
  expect(result?.command.name).toBe("diff");
});

test("shows colorized diff output", async () => {
  (getDiff as any).mockResolvedValue({ diff: sampleDiff });

  const ctx = createMockContext();
  await resolve("/diff")!.command.handler("", ctx);

  const output = getMessage(ctx);
  expect(output).toContain("Diff");
  expect(output).toContain("1 file(s)");
  expect(output).toContain("src/app.ts");
});

test("passes file argument to API", async () => {
  (getDiff as any).mockResolvedValue({ diff: sampleDiff });

  const ctx = createMockContext();
  await resolve("/diff")!.command.handler("src/app.ts", ctx);

  expect(getDiff).toHaveBeenCalledWith({ file: "src/app.ts", staged: false });
});

test("passes --staged flag", async () => {
  (getDiff as any).mockResolvedValue({ diff: sampleDiff });

  const ctx = createMockContext();
  await resolve("/diff")!.command.handler("--staged", ctx);

  expect(getDiff).toHaveBeenCalledWith({ file: undefined, staged: true });
});

test("passes file and staged together", async () => {
  (getDiff as any).mockResolvedValue({ diff: sampleDiff });

  const ctx = createMockContext();
  await resolve("/diff")!.command.handler("src/app.ts --staged", ctx);

  expect(getDiff).toHaveBeenCalledWith({ file: "src/app.ts", staged: true });
});

test.each(["staged", "-s", "--staged"])("recognizes '%s' as staged flag", async (flag) => {
  (getDiff as any).mockResolvedValue({ diff: sampleDiff });

  const ctx = createMockContext();
  await resolve("/diff")!.command.handler(flag, ctx);

  expect(getDiff).toHaveBeenCalledWith({ file: undefined, staged: true });
});

test("shows no changes message", async () => {
  (getDiff as any).mockResolvedValue({
    diff: "No differences found.",
  });

  const ctx = createMockContext();
  await resolve("/diff")!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("No unstaged changes");
});

test("shows no staged changes message", async () => {
  (getDiff as any).mockResolvedValue({
    diff: "No differences found.",
  });

  const ctx = createMockContext();
  await resolve("/diff")!.command.handler("--staged", ctx);

  expect(getMessage(ctx)).toContain("No staged changes");
});

test("handles API error gracefully", async () => {
  (getDiff as any).mockRejectedValue(new Error("network error"));

  const ctx = createMockContext();
  await resolve("/diff")!.command.handler("", ctx);

  expect(getMessage(ctx)).toContain("Diff failed");
});

test.each([
  { line: "+added line", contains: "added line" },
  { line: "-removed line", contains: "removed line" },
  { line: "@@ -1,3 +1,4 @@", contains: "@@ -1,3 +1,4 @@" },
  { line: "diff --git a/f b/f", contains: "diff --git" },
  { line: " context line", contains: "context line" },
])("colorizeDiff renders '$line'", ({ line, contains }) => {
  const result = colorizeDiff(line);
  expect(result).toContain(contains);
});

test.each([
  {
    diff: sampleDiff,
    expected: { files: 1, additions: 2, deletions: 1 },
  },
  {
    diff: "No differences found.",
    expected: { files: 0, additions: 0, deletions: 0 },
  },
  {
    diff: "diff --git a/a b/a\ndiff --git a/b b/b\n+x\n+y\n-z\n",
    expected: { files: 2, additions: 2, deletions: 1 },
  },
])("parseDiffStats returns correct counts", ({ diff, expected }) => {
  expect(parseDiffStats(diff)).toEqual(expected);
});
