import { expect, test } from "vitest";
import { DEFAULT_SERVER_URL, DEFAULT_MODE, DEFAULT_MODEL, MODES } from "../constants.js";

test.each([
  { name: "DEFAULT_SERVER_URL", value: DEFAULT_SERVER_URL, expected: "https://api.loomkin.dev" },
  { name: "DEFAULT_MODE", value: DEFAULT_MODE, expected: "code" },
  { name: "DEFAULT_MODEL", value: DEFAULT_MODEL, expected: "" },
])("$name equals $expected", ({ value, expected }) => {
  expect(value).toBe(expected);
});

test("DEFAULT_MODE is included in MODES", () => {
  expect(MODES).toContain(DEFAULT_MODE);
});

test.each(["code", "plan", "chat"] as const)("MODES contains %s", (mode) => {
  expect(MODES).toContain(mode);
});

test("MODES has exactly 3 entries", () => {
  expect(MODES.length).toBe(3);
});
