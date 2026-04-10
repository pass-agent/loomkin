import { describe, expect, test } from "vitest";
import {
  buildModelOptions,
  getCenteredWindowStart,
  getInitialModelIndex,
  getWindowStartForSelection,
} from "./modelPickerState.js";
import type { ModelProvider } from "../lib/types.js";

const providers: ModelProvider[] = [
  {
    id: "anthropic",
    name: "Anthropic",
    status: { type: "oauth", status: "connected" },
    models: [{ id: "anthropic:claude-sonnet", label: "Claude Sonnet", context: "200K ctx" }],
  },
  {
    id: "openai",
    name: "OpenAI",
    status: { type: "oauth", status: "connected" },
    models: [
      { id: "openai:gpt-5.3-codex", label: "gpt-5.3-codex", context: null },
      { id: "openai:gpt-5.4", label: "gpt-5.4", context: null },
    ],
  },
];

describe("modelPickerState", () => {
  test("buildModelOptions flattens models without separator rows", () => {
    const options = buildModelOptions(providers);

    expect(options).toHaveLength(3);
    expect(options.map((option) => option.id)).toEqual([
      "anthropic:claude-sonnet",
      "openai:gpt-5.3-codex",
      "openai:gpt-5.4",
    ]);
  });

  test("getInitialModelIndex selects the current model when present", () => {
    const options = buildModelOptions(providers);

    expect(getInitialModelIndex(options, "openai:gpt-5.4")).toBe(2);
    expect(getInitialModelIndex(options, "missing:model")).toBe(0);
  });

  test("window helpers keep selection centered and then pinned in view", () => {
    expect(getCenteredWindowStart(6, 5)).toBe(4);
    expect(getWindowStartForSelection(4, 3, 5)).toBe(3);
    expect(getWindowStartForSelection(4, 8, 5)).toBe(4);
    expect(getWindowStartForSelection(4, 10, 5)).toBe(6);
  });
});
