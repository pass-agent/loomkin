import { expect, test, vi, beforeEach } from "vitest";

vi.mock("../config.js", () => ({
  getConfig: () => ({
    serverUrl: "https://loom.test",
    token: "test-token",
    defaultMode: "code",
    defaultModel: "anthropic:claude-opus-4",
  }),
}));

vi.mock("../../stores/appStore.js", () => ({
  useAppStore: {
    getState: () => ({
      model: "anthropic:claude-opus-4",
      verbose: false,
    }),
  },
}));

const mockSendMessageRest = vi.fn();
const mockCreateSession = vi.fn();

vi.mock("../api.js", () => ({
  sendMessageRest: (...args: unknown[]) => mockSendMessageRest(...args),
  createSession: (...args: unknown[]) => mockCreateSession(...args),
  ApiError: class extends Error {
    constructor(
      public status: number,
      public body: string,
    ) {
      super(`API ${status}: ${body}`);
    }
  },
}));

const { runPrintMode } = await import("../print.js");

beforeEach(() => {
  vi.resetAllMocks();
  mockCreateSession.mockResolvedValue({
    session: { id: "new-session-id" },
  });
});

test.each([
  {
    name: "text format outputs content only",
    format: "text" as const,
    response: { id: "msg1", role: "assistant", content: "Hello world" },
    expected: "Hello world\n",
  },
  {
    name: "text format handles null content",
    format: "text" as const,
    response: { id: "msg2", role: "assistant", content: null },
    expected: "\n",
  },
  {
    name: "json format outputs full message object",
    format: "json" as const,
    response: {
      id: "msg3",
      role: "assistant",
      content: "result",
      tool_calls: null,
    },
    expected: JSON.stringify(
      { id: "msg3", role: "assistant", content: "result", tool_calls: null },
      null,
      2,
    ) + "\n",
  },
])("$name", async ({ format, response, expected }) => {
  mockSendMessageRest.mockResolvedValue({ message: response });

  const writeSpy = vi.spyOn(process.stdout, "write").mockImplementation(() => true);

  await runPrintMode({
    prompt: "test prompt",
    outputFormat: format,
    sessionId: "existing-session",
  });

  expect(writeSpy).toHaveBeenCalledWith(expected);
  expect(mockSendMessageRest).toHaveBeenCalledWith("existing-session", "test prompt");
  writeSpy.mockRestore();
});

test("creates session when no sessionId provided", async () => {
  mockSendMessageRest.mockResolvedValue({
    message: { id: "msg1", role: "assistant", content: "ok" },
  });

  const writeSpy = vi.spyOn(process.stdout, "write").mockImplementation(() => true);

  await runPrintMode({ prompt: "hello", outputFormat: "text" });

  expect(mockCreateSession).toHaveBeenCalledWith({
    model: "anthropic:claude-opus-4",
    project_path: expect.any(String),
  });
  expect(mockSendMessageRest).toHaveBeenCalledWith("new-session-id", "hello");
  writeSpy.mockRestore();
});

test("uses existing sessionId when provided", async () => {
  mockSendMessageRest.mockResolvedValue({
    message: { id: "msg1", role: "assistant", content: "ok" },
  });

  const writeSpy = vi.spyOn(process.stdout, "write").mockImplementation(() => true);

  await runPrintMode({
    prompt: "hello",
    outputFormat: "text",
    sessionId: "my-session",
  });

  expect(mockCreateSession).not.toHaveBeenCalled();
  expect(mockSendMessageRest).toHaveBeenCalledWith("my-session", "hello");
  writeSpy.mockRestore();
});
