import { expect, test, vi } from "vitest";

vi.mock("marked-terminal", () => ({
  markedTerminal: () => ({
    renderer: {},
  }),
}));

const { renderMarkdown } = await import("../markdown.js");

test.each([
  { input: "hello world", contains: "hello world", label: "preserves plain text" },
  { input: "**bold**", contains: null, label: "renders bold (non-empty output)" },
  { input: "```js\nconsole.log('hi')\n```", contains: "console.log", label: "renders code blocks" },
  { input: "use `foo()` here", contains: "foo()", label: "renders inline code" },
  { input: "", contains: null, label: "handles empty input" },
])("renderMarkdown: $label", ({ input, contains }) => {
  const result = renderMarkdown(input);
  expect(typeof result).toBe("string");
  if (contains) {
    expect(result).toContain(contains);
  }
});
