import { expect, test, beforeEach, vi } from "vitest";
import type { ConnectionState, AppError } from "../appStore.js";

vi.mock("../../lib/config.js", () => ({
  getConfig: () => ({
    serverUrl: "https://loom.test",
    token: "test-token",
    defaultMode: "code",
    defaultModel: "anthropic:claude-opus-4",
  }),
}));

const { appStore } = await import("../appStore.js");

beforeEach(() => {
  appStore.setState({
    serverUrl: "https://loom.test",
    token: "test-token",
    mode: "code",
    model: "anthropic:claude-opus-4",
    connectionState: "disconnected",
    reconnectAttempts: 0,
    errors: [],
    verbose: false,
    debug: false,
    skipPermissions: false,
    allowedTools: null,
    disallowedTools: null,
    maxTurns: null,
  });
});

test("initial state loads from config", () => {
  const state = appStore.getState();
  expect(state.serverUrl).toBe("https://loom.test");
  expect(state.token).toBe("test-token");
  expect(state.mode).toBe("code");
  expect(state.model).toBe("anthropic:claude-opus-4");
});

test.each(["code", "plan", "chat"] as const)(
  "setMode(%s) updates mode",
  (mode) => {
    appStore.getState().setMode(mode);
    expect(appStore.getState().mode).toBe(mode);
  },
);

test("setModel updates model", () => {
  appStore.getState().setModel("claude-sonnet-4");
  expect(appStore.getState().model).toBe("claude-sonnet-4");
});

test.each<{ state: ConnectionState; expectedConnected: boolean }>([
  { state: "disconnected", expectedConnected: false },
  { state: "connecting", expectedConnected: false },
  { state: "connected", expectedConnected: true },
  { state: "reconnecting", expectedConnected: false },
])(
  "setConnectionState($state) → isConnected=$expectedConnected",
  ({ state, expectedConnected }) => {
    appStore.getState().setConnectionState(state);
    expect(appStore.getState().connectionState).toBe(state);
    expect(appStore.getState().isConnected).toBe(expectedConnected);
  },
);

test("setConnectionState(connected) resets reconnectAttempts and clears network errors", () => {
  appStore.setState({ reconnectAttempts: 5 });
  appStore.getState().addError({
    type: "network",
    message: "lost connection",
    recoverable: true,
  });
  appStore.getState().addError({
    type: "session",
    message: "session error",
    recoverable: false,
  });

  appStore.getState().setConnectionState("connected");

  expect(appStore.getState().reconnectAttempts).toBe(0);
  // Network errors cleared, session errors kept
  expect(appStore.getState().errors).toHaveLength(1);
  expect(appStore.getState().errors[0].type).toBe("session");
});

test("incrementReconnectAttempts increments counter", () => {
  appStore.getState().incrementReconnectAttempts();
  appStore.getState().incrementReconnectAttempts();
  expect(appStore.getState().reconnectAttempts).toBe(2);
});

test.each<{ token: string | null; label: string }>([
  { token: "new-token", label: "sets token" },
  { token: null, label: "clears token" },
])("setToken $label", ({ token }) => {
  appStore.getState().setToken(token);
  expect(appStore.getState().token).toBe(token);
});

test.each<{ error: AppError }>([
  {
    error: {
      type: "network",
      message: "timeout",
      recoverable: true,
      action: "retry",
    },
  },
  {
    error: {
      type: "auth",
      message: "expired",
      recoverable: true,
      action: "reauth",
    },
  },
  {
    error: {
      type: "session",
      message: "not found",
      recoverable: true,
      action: "new_session",
    },
  },
  { error: { type: "api", message: "500 error", recoverable: false } },
])("addError adds $error.type error", ({ error }) => {
  appStore.getState().addError(error);
  const errors = appStore.getState().errors;
  expect(errors).toHaveLength(1);
  expect(errors[0]).toEqual(error);
});

test("dismissError removes error by index", () => {
  appStore.getState().addError({
    type: "network",
    message: "a",
    recoverable: true,
  });
  appStore.getState().addError({
    type: "api",
    message: "b",
    recoverable: false,
  });

  appStore.getState().dismissError(0);

  expect(appStore.getState().errors).toHaveLength(1);
  expect(appStore.getState().errors[0].message).toBe("b");
});

test("clearErrors empties the errors array", () => {
  appStore.getState().addError({
    type: "network",
    message: "a",
    recoverable: true,
  });
  appStore.getState().addError({
    type: "api",
    message: "b",
    recoverable: false,
  });

  appStore.getState().clearErrors();
  expect(appStore.getState().errors).toHaveLength(0);
});

// --- CLI flag state ---

test.each([
  { setter: "setVerbose" as const, field: "verbose" as const, value: true },
  { setter: "setDebug" as const, field: "debug" as const, value: true },
  { setter: "setSkipPermissions" as const, field: "skipPermissions" as const, value: true },
])("$setter sets $field to $value", ({ setter, field, value }) => {
  appStore.getState()[setter](value);
  expect(appStore.getState()[field]).toBe(value);
});

test("setAllowedTools sets and clears tool list", () => {
  appStore.getState().setAllowedTools(["shell", "file_read"]);
  expect(appStore.getState().allowedTools).toEqual(["shell", "file_read"]);

  appStore.getState().setAllowedTools(null);
  expect(appStore.getState().allowedTools).toBeNull();
});

test("setDisallowedTools sets and clears tool list", () => {
  appStore.getState().setDisallowedTools(["git"]);
  expect(appStore.getState().disallowedTools).toEqual(["git"]);

  appStore.getState().setDisallowedTools(null);
  expect(appStore.getState().disallowedTools).toBeNull();
});

test.each([
  { turns: 5, expected: 5 },
  { turns: null, expected: null },
])("setMaxTurns($turns) sets maxTurns to $expected", ({ turns, expected }) => {
  appStore.getState().setMaxTurns(turns);
  expect(appStore.getState().maxTurns).toBe(expected);
});
