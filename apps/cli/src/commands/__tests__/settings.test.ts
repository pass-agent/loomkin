import { expect, test, vi, beforeEach } from "vitest";
import type { CommandContext } from "../registry.js";
import type { AppState } from "../../stores/appStore.js";
import type { SessionState } from "../../stores/sessionStore.js";
import type { Setting } from "../../lib/types.js";

vi.mock("../../lib/api.js", () => ({
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
  ApiError: class ApiError extends Error {
    constructor(
      public status: number,
      public body: string,
    ) {
      super(`API ${status}: ${body}`);
      this.name = "ApiError";
    }
    get isAuth() {
      return this.status === 401 || this.status === 403;
    }
    get isNotFound() {
      return this.status === 404;
    }
    get isServer() {
      return this.status >= 500;
    }
  },
}));

// Static imports after vi.mock — vi.mock is hoisted so these receive the mocked module
import { resolve } from "../registry.js";
import { getSettings, updateSettings, ApiError } from "../../lib/api.js";

function makeSetting(overrides: Partial<Setting> = {}): Setting {
  return {
    key: "teams.orchestrator_mode",
    label: "Orchestrator mode",
    description: "Lead agent orchestrates work across the team",
    type: "toggle",
    default: true,
    value: true,
    tab: "Agents",
    section: "Team Structure",
    options: null,
    range: null,
    unit: null,
    step: null,
    ...overrides,
  };
}

const mockSettings: Setting[] = [
  makeSetting(),
  makeSetting({
    key: "teams.max_nesting_depth",
    label: "Max nesting depth",
    type: "number",
    default: 3,
    value: 3,
    range: { min: 1, max: 5 },
    step: 1,
  }),
  makeSetting({
    key: "teams.consensus.quorum",
    label: "Consensus quorum",
    type: "select",
    default: "majority",
    value: "majority",
    options: ["majority", "unanimous"],
    section: "Consensus & Debate",
  }),
  makeSetting({
    key: "budget.max_per_team_usd",
    label: "Max budget per team",
    type: "currency",
    default: 10,
    value: 25,
    tab: "Budgets",
    section: "Team & Agent Budgets",
    unit: "$",
  }),
  makeSetting({
    key: "safety.auto_approve",
    label: "Auto-approve patterns",
    type: "tag_list",
    default: [],
    value: ["read", "search"],
    tab: "Safety",
    section: "Permissions & Auto-Approve",
  }),
];

function createMockContext(): CommandContext {
  return {
    appStore: {
      mode: "code",
      model: "anthropic:claude-opus-4",
      setMode: vi.fn(),
      setModel: vi.fn(),
    } as unknown as AppState,
    sessionStore: {
      sessionId: "test-session-123",
      setSessionId: vi.fn(),
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

beforeEach(async () => {
  vi.clearAllMocks();
  (getSettings as any).mockResolvedValue({ settings: mockSettings });
  (updateSettings as any).mockResolvedValue({ message: "settings updated", values: {} });
  await import("../settings.js");
});

// -- Subcommand routing --

test.each([
  { args: "", contains: "Settings Tabs", label: "no args shows tabs" },
  { args: "Agents", contains: "Team Structure", label: "tab name shows sections" },
  { args: "agents", contains: "Team Structure", label: "tab name is case-insensitive" },
  {
    args: "teams.orchestrator_mode",
    contains: "Orchestrator mode",
    label: "dotted key shows detail",
  },
  { args: "search budget", contains: "budget", label: "search finds matches" },
])("/settings $label", async ({ args, contains }) => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler(args, ctx);
  expect(getMessage(ctx).toLowerCase()).toContain(contains.toLowerCase());
});

// -- Tab listing --

test("tabs list shows all unique tabs with counts", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("", ctx);
  const msg = getMessage(ctx);
  expect(msg).toContain("Agents");
  expect(msg).toContain("Budgets");
  expect(msg).toContain("Safety");
});

// -- Unknown tab --

test("unknown tab shows available tabs", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("nonexistent", ctx);
  expect(getMessage(ctx)).toContain("Unknown tab");
  expect(getMessage(ctx)).toContain("Agents");
});

// -- Setting detail --

test("setting detail shows key, type, value, default", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("teams.max_nesting_depth", ctx);
  const msg = getMessage(ctx);
  expect(msg).toContain("teams.max_nesting_depth");
  expect(msg).toContain("number");
  expect(msg).toContain("3");
  expect(msg).toContain("1");
  expect(msg).toContain("5");
});

test("setting detail shows options for select type", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("teams.consensus.quorum", ctx);
  const msg = getMessage(ctx);
  expect(msg).toContain("majority");
  expect(msg).toContain("unanimous");
});

test("unknown setting key shows not found", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("nonexistent.key", ctx);
  expect(getMessage(ctx)).toContain("not found");
});

// -- Update --

test("update setting calls API and confirms", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("teams.orchestrator_mode=false", ctx);
  expect(updateSettings).toHaveBeenCalledWith({
    "teams.orchestrator_mode": false,
  });
  expect(getMessage(ctx)).toContain("Updated");
});

test("update with invalid value shows error", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("teams.max_nesting_depth=notanumber", ctx);
  expect(updateSettings).not.toHaveBeenCalled();
  expect(getMessage(ctx)).toContain("Invalid number");
});

test("update with out-of-range value shows error", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("teams.max_nesting_depth=99", ctx);
  expect(updateSettings).not.toHaveBeenCalled();
  expect(getMessage(ctx)).toContain("between 1 and 5");
});

test("update with invalid select option shows error", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("teams.consensus.quorum=invalid", ctx);
  expect(updateSettings).not.toHaveBeenCalled();
  expect(getMessage(ctx)).toContain("Invalid option");
});

test("update 422 shows validation error", async () => {
  (updateSettings as any).mockRejectedValueOnce(
    new ApiError(422, JSON.stringify({ errors: { key: "must be positive" } })),
  );
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("teams.orchestrator_mode=true", ctx);
  expect(getMessage(ctx)).toContain("must be positive");
});

// -- Search --

test("search with no results shows message", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("search zzzzz", ctx);
  expect(getMessage(ctx)).toContain("No settings matching");
});

test("search matches across key, label, and description", async () => {
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("search orchestrat", ctx);
  expect(getMessage(ctx)).toContain("teams.orchestrator_mode");
});

// -- API fetch error --

test("API error on fetch shows error message", async () => {
  (getSettings as any).mockRejectedValueOnce(new ApiError(500, "Internal server error"));
  const ctx = createMockContext();
  await resolve("/settings")!.command.handler("", ctx);
  expect(getMessage(ctx)).toContain("Failed to fetch settings");
});

// -- Value parsing --

test.each([
  { type: "toggle", raw: "true", expected: true },
  { type: "toggle", raw: "false", expected: false },
  { type: "toggle", raw: "on", expected: true },
  { type: "toggle", raw: "off", expected: false },
  { type: "toggle", raw: "1", expected: true },
  { type: "toggle", raw: "0", expected: false },
  { type: "number", raw: "42", expected: 42 },
  { type: "number", raw: "3.14", expected: 3.14 },
  { type: "duration", raw: "5000", expected: 5000 },
  { type: "currency", raw: "10.50", expected: 10.5 },
  { type: "select", raw: "majority", expected: "majority" },
  { type: "tag_list", raw: "a,b,c", expected: ["a", "b", "c"] },
  { type: "tag_list", raw: " a , b , c ", expected: ["a", "b", "c"] },
  { type: "tag_list", raw: "", expected: [] },
])("parseValueForType($type, $raw) → $expected", async ({ type, raw, expected }) => {
  const { parseValueForType } = await import("../settings.js");
  const setting = makeSetting({
    type,
    options: type === "select" ? ["majority", "unanimous"] : null,
  });
  expect(parseValueForType(type, raw, setting)).toEqual(expected);
});

test.each([
  { type: "toggle", raw: "maybe", error: "Invalid toggle" },
  { type: "number", raw: "abc", error: "Invalid number" },
])("parseValueForType($type, $raw) throws", async ({ type, raw, error }) => {
  const { parseValueForType } = await import("../settings.js");
  const setting = makeSetting({ type });
  expect(() => parseValueForType(type, raw, setting)).toThrow(error);
});
