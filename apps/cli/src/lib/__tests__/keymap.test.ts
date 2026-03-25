import { expect, test } from "vitest";
import {
  matchKey,
  findAction,
  getVimKeymap,
  defaultKeymap,
  vimNormalKeymap,
  vimInsertKeymap,
  type KeyBinding,
} from "../keymap.js";

test.each([
  {
    label: "ctrl+c matches ctrl+c binding",
    input: { key: "c", ctrl: true },
    binding: { key: "c", ctrl: true, action: "quit" } as KeyBinding,
    expected: true,
  },
  {
    label: "c without ctrl does not match ctrl+c binding",
    input: { key: "c" },
    binding: { key: "c", ctrl: true, action: "quit" } as KeyBinding,
    expected: false,
  },
  {
    label: "ctrl+x does not match ctrl+c binding",
    input: { key: "x", ctrl: true },
    binding: { key: "c", ctrl: true, action: "quit" } as KeyBinding,
    expected: false,
  },
  {
    label: "enter matches enter binding (no modifiers)",
    input: { key: "enter" },
    binding: { key: "enter", action: "submit" } as KeyBinding,
    expected: true,
  },
  {
    label: "shift+enter matches shift+enter binding",
    input: { key: "enter", shift: true },
    binding: { key: "enter", shift: true, action: "newline" } as KeyBinding,
    expected: true,
  },
  {
    label: "enter without shift does not match shift+enter binding",
    input: { key: "enter" },
    binding: { key: "enter", shift: true, action: "newline" } as KeyBinding,
    expected: false,
  },
  {
    label: "meta+k matches meta+k binding",
    input: { key: "k", meta: true },
    binding: { key: "k", meta: true, action: "scrollUp" } as KeyBinding,
    expected: true,
  },
  {
    label: "k without meta does not match meta+k binding",
    input: { key: "k" },
    binding: { key: "k", meta: true, action: "scrollUp" } as KeyBinding,
    expected: false,
  },
  {
    label: "undefined modifiers treated as false",
    input: { key: "l", ctrl: true, shift: undefined, meta: undefined },
    binding: { key: "l", ctrl: true, action: "clear" } as KeyBinding,
    expected: true,
  },
])("matchKey: $label", ({ input, binding, expected }) => {
  expect(matchKey(input, binding)).toBe(expected);
});

test.each(["quit", "clear", "scrollUp", "scrollDown", "toggleSplit"])(
  "defaultKeymap contains %s action",
  (action) => {
    expect(defaultKeymap.some((b) => b.action === action)).toBe(true);
  },
);

test("ctrl+c is mapped to quit in defaultKeymap", () => {
  expect(
    defaultKeymap.some((b) => b.action === "quit" && b.key === "c" && b.ctrl),
  ).toBe(true);
});

// findAction tests
test.each([
  {
    label: "finds ctrl+c quit action in default keymap",
    input: { key: "c", ctrl: true },
    keymap: defaultKeymap,
    expected: "quit",
  },
  {
    label: "finds ctrl+l clear action",
    input: { key: "l", ctrl: true },
    keymap: defaultKeymap,
    expected: "clear",
  },
  {
    label: "returns null for unbound key",
    input: { key: "z" },
    keymap: defaultKeymap,
    expected: null,
  },
  {
    label: "finds i insert action in vim normal keymap",
    input: { key: "i" },
    keymap: vimNormalKeymap,
    expected: "vim:insert",
  },
  {
    label: "finds escape normal action in vim insert keymap",
    input: { key: "escape" },
    keymap: vimInsertKeymap,
    expected: "vim:normal",
  },
  {
    label: "finds h left action in vim normal",
    input: { key: "h" },
    keymap: vimNormalKeymap,
    expected: "vim:left",
  },
  {
    label: "finds j scrollDown in vim normal",
    input: { key: "j" },
    keymap: vimNormalKeymap,
    expected: "scrollDown",
  },
  {
    label: "finds w wordForward in vim normal",
    input: { key: "w" },
    keymap: vimNormalKeymap,
    expected: "vim:wordForward",
  },
])("findAction: $label", ({ input, keymap, expected }) => {
  expect(findAction(input, keymap)).toBe(expected);
});

// getVimKeymap tests
test.each([
  { mode: "normal" as const, expectedAction: "vim:insert" },
  { mode: "insert" as const, expectedAction: "vim:normal" },
  { mode: "command" as const, expectedAction: "vim:normal" },
])("getVimKeymap($mode) includes $expectedAction", ({ mode, expectedAction }) => {
  const keymap = getVimKeymap(mode);
  expect(keymap.some((b) => b.action === expectedAction)).toBe(true);
});

// Vim normal keymap completeness
test.each([
  "vim:insert",
  "vim:append",
  "vim:left",
  "vim:right",
  "vim:wordForward",
  "vim:wordBackward",
  "vim:lineStart",
  "vim:lineEnd",
  "vim:deleteChar",
  "vim:undo",
  "vim:command",
  "scrollDown",
  "scrollUp",
])("vim normal keymap contains %s action", (action) => {
  expect(vimNormalKeymap.some((b) => b.action === action)).toBe(true);
});

// Vim insert keymap has escape
test("vim insert keymap has escape to normal", () => {
  expect(
    vimInsertKeymap.some(
      (b) => b.action === "vim:normal" && b.key === "escape",
    ),
  ).toBe(true);
});

// Vim insert keymap has ctrl+[ as escape alternative
test("vim insert keymap has ctrl+[ as escape", () => {
  expect(
    vimInsertKeymap.some(
      (b) => b.action === "vim:normal" && b.key === "[" && b.ctrl,
    ),
  ).toBe(true);
});
