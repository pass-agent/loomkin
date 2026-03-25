import { expect, test, beforeEach, vi } from "vitest";
import { resolve } from "../registry.js";
import type { CommandContext } from "../registry.js";
import { useAppStore } from "../../stores/appStore.js";

vi.mock("../../lib/config.js", () => ({
  getConfig: () => ({
    serverUrl: "https://loom.test",
    token: null,
    defaultMode: "code",
    defaultModel: "anthropic:claude-opus-4",
    lastSessionId: null,
    theme: "loomkin",
    keybindMode: "default",
  }),
  setConfig: vi.fn(),
}));

// Import after mocks
await import("../keybinds.js");

function createMockContext(): CommandContext {
  return {
    appStore: useAppStore.getState(),
    sessionStore: {} as CommandContext["sessionStore"],
    addSystemMessage: vi.fn(),
    sendMessage: vi.fn(),
    clearMessages: vi.fn(),
    exit: vi.fn(),
  };
}

beforeEach(() => {
  useAppStore.getState().setKeybindMode("default");
  useAppStore.getState().setVimMode("normal");
});

test.each([
  { input: "/keybinds", args: "" },
  { input: "/kb", args: "" },
  { input: "/keys", args: "" },
])("$input resolves to keybinds command", ({ input }) => {
  const result = resolve(input);
  expect(result).not.toBeNull();
  expect(result!.command.name).toBe("keybinds");
});

test.each([
  {
    label: "no args shows current mode and bindings",
    args: "",
    expectContains: "Keybinding mode: default",
  },
  {
    label: "show subcommand shows current mode",
    args: "show",
    expectContains: "Keybinding mode: default",
  },
  {
    label: "vim mode switch confirms",
    args: "vim",
    expectContains: 'set to "vim"',
  },
  {
    label: "default mode switch confirms",
    args: "default",
    expectContains: 'set to "default"',
  },
  {
    label: "unknown mode shows error",
    args: "emacs",
    expectContains: "Unknown keybinding mode",
  },
])("keybinds handler: $label", ({ args, expectContains }) => {
  const ctx = createMockContext();
  const result = resolve(`/keybinds ${args}`.trim());
  result!.command.handler(result!.args, ctx);
  const msg = (ctx.addSystemMessage as ReturnType<typeof vi.fn>).mock
    .calls[0][0] as string;
  expect(msg).toContain(expectContains);
});

test("switching to vim updates appStore keybindMode", () => {
  const ctx = createMockContext();
  const result = resolve("/keybinds vim");
  result!.command.handler(result!.args, ctx);
  expect(useAppStore.getState().keybindMode).toBe("vim");
});

test("switching to vim persists to config", async () => {
  const { setConfig } = await import("../../lib/config.js");
  const ctx = createMockContext();
  const result = resolve("/keybinds vim");
  result!.command.handler(result!.args, ctx);
  expect(setConfig).toHaveBeenCalledWith({ keybindMode: "vim" });
});

test("show in vim mode displays vim-specific bindings", () => {
  useAppStore.getState().setKeybindMode("vim");
  const ctx = createMockContext();
  const result = resolve("/keybinds show");
  result!.command.handler(result!.args, ctx);
  const msg = (ctx.addSystemMessage as ReturnType<typeof vi.fn>).mock
    .calls[0][0] as string;
  expect(msg).toContain("Normal mode");
  expect(msg).toContain("Insert mode");
  expect(msg).toContain("Escape");
});
