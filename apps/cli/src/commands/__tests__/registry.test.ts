import { expect, test, beforeEach } from "vitest";

let registry: typeof import("../registry.js");

beforeEach(async () => {
  registry = await import("../registry.js");
  await import("../help.js");
  await import("../clear.js");
  await import("../mode.js");
  await import("../model.js");
  await import("../quit.js");
  await import("../compact.js");
  await import("../session.js");
  await import("../mcp.js");
});

test("getAllCommands returns all registered commands sorted by name", () => {
  const commands = registry.getAllCommands();
  const names = commands.map((c) => c.name);
  expect(names.length).toBeGreaterThanOrEqual(8);
  expect(names).toEqual([...names].sort());
  for (const expected of ["help", "clear", "mode", "model", "exit", "compact", "session", "mcp"]) {
    expect(names).toContain(expected);
  }
});

test.each([
  { input: "/help", expectedName: "help", expectedArgs: "" },
  { input: "/mode plan", expectedName: "mode", expectedArgs: "plan" },
  { input: "/q", expectedName: "exit", expectedArgs: "" },
  { input: "/HELP", expectedName: "help", expectedArgs: "" },
  { input: "  /mode   chat  ", expectedName: "mode", expectedArgs: "chat" },
])("resolve($input) → command=$expectedName args=$expectedArgs", ({ input, expectedName, expectedArgs }) => {
  const result = registry.resolve(input);
  expect(result).not.toBeNull();
  expect(result!.command.name).toBe(expectedName);
  expect(result!.args).toBe(expectedArgs);
});

test.each([
  { input: "/nonexistent", label: "unknown command" },
  { input: "help", label: "non-slash input" },
])("resolve returns null for $label ($input)", ({ input }) => {
  expect(registry.resolve(input)).toBeNull();
});

test.each([
  { partial: "mo", expected: ["mode", "model"] },
  { partial: "/he", expected: ["help"] },
  { partial: "cls", expected: ["clear"] },
])("getCompletions($partial) contains $expected", ({ partial, expected }) => {
  const names = registry.getCompletions(partial).map((c) => c.name);
  for (const name of expected) {
    expect(names).toContain(name);
  }
});

test("getCompletions with empty query returns all commands", () => {
  expect(registry.getCompletions("").length).toBeGreaterThanOrEqual(8);
});
