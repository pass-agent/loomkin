import React from "react";
import { describe, expect, test, beforeEach } from "vitest";
import { OrchestrationEpicCard } from "../OrchestrationEpicCard.js";
import { epicCardStore, type EpicCard } from "../../stores/epicCardStore.js";

/**
 * We can't pull ink-testing-library in (not installed) and React 19 has
 * deprecated react-test-renderer, so we walk the React element tree
 * ourselves and assert on the flattened text. This is enough to verify
 * the structural pieces the user expects to see in the card.
 */

type ReactNode = React.ReactNode;

function elementText(node: ReactNode): string {
  if (node === null || node === undefined || typeof node === "boolean") {
    return "";
  }
  if (typeof node === "string" || typeof node === "number") {
    return String(node);
  }
  if (Array.isArray(node)) {
    return node.map(elementText).join(" ");
  }
  if (React.isValidElement(node)) {
    // Recurse into children
    const props = (node.props as { children?: ReactNode }) ?? {};
    return elementText(props.children);
  }
  return "";
}

function renderText(card: EpicCard, now?: number): string {
  // The component is a plain functional component — invoke directly.
  const element = OrchestrationEpicCard({
    card,
    now: now ?? card.started_at + 42_000,
  });
  return elementText(element);
}

function base(): EpicCard {
  return {
    epic_id: "epic-abc",
    current_phase: "research",
    current_persona: {
      name: "Researcher",
      icon: "🔬",
      role_blurb: "gathers context from your project",
    },
    work_unit_count: 0,
    gate_progress: {},
    status: "monitoring",
    last_event_text: "🔬 Researcher: entered research",
    diff_summaries: [],
    started_at: 1_700_000_000_000,
  };
}

function makeCard(overrides: Partial<EpicCard> = {}): EpicCard {
  return { ...base(), ...overrides };
}

beforeEach(() => {
  epicCardStore.getState().reset();
});

describe("OrchestrationEpicCard", () => {
  test("renders persona name, icon, role blurb and epic id", () => {
    const text = renderText(makeCard());
    expect(text).toContain("Researcher");
    expect(text).toContain("🔬");
    expect(text).toContain("gathers context");
    expect(text).toContain("epic-abc");
  });

  test("renders phase, work-unit count, last event line", () => {
    const text = renderText(makeCard({ work_unit_count: 3 }));
    expect(text).toContain("research");
    expect(text).toContain("3");
    expect(text).toContain("entered research");
  });

  test("renders the 9-dot progress bar with the correct number filled", () => {
    // 'research' is index 0 → 1 filled + 8 empty
    const text = renderText(makeCard({ current_phase: "research" }));
    const filled = (text.match(/●/g) ?? []).length;
    const empty = (text.match(/○/g) ?? []).length;
    expect(filled).toBe(1);
    expect(empty).toBe(8);
  });

  test("dots scale with phase progress", () => {
    // 'decompose' is index 4 → 5 filled + 4 empty
    const text = renderText(makeCard({ current_phase: "decompose" }));
    expect((text.match(/●/g) ?? []).length).toBe(5);
    expect((text.match(/○/g) ?? []).length).toBe(4);
  });

  test("renders the static action hints", () => {
    const text = renderText(makeCard());
    expect(text).toContain("pause");
    expect(text).toContain("cancel");
    expect(text).toContain("open dashboard");
  });

  test("renders the elapsed time string", () => {
    const text = renderText(makeCard());
    expect(text).toContain("0:42");
  });

  test("renders failed banner when status is failed", () => {
    const text = renderText(makeCard({ status: "failed" }));
    expect(text).toContain("failed");
  });

  test("renders escalated banner when status is escalated", () => {
    const text = renderText(makeCard({ status: "escalated" }));
    expect(text).toContain("escalated");
  });

  test("renders without persona gracefully", () => {
    const text = renderText(makeCard({ current_persona: null }));
    expect(text).toContain("Orchestration");
    expect(text).toContain("epic-abc");
  });

  test("shows diff count when summaries are present", () => {
    const text = renderText(
      makeCard({
        diff_summaries: [
          { work_unit_id: "wu-1", stats: "+10 -1" },
          { work_unit_id: "wu-2", stats: "+3 -0" },
        ],
      }),
    );
    expect(text).toContain("Diffs");
    expect(text).toContain("2");
  });

  test("can be driven by the store applyEvent pipeline", () => {
    const epicId = "epic-store-drive";
    epicCardStore.getState().applyEvent({
      subtype: "epic",
      event: "created",
      epic_id: epicId,
    });
    epicCardStore.getState().applyEvent({
      subtype: "epic",
      event: ["phase_entered", "plan"],
      epic_id: epicId,
      persona: { name: "Planner", icon: "📋", role_blurb: "drafts work units" },
    });

    const card = epicCardStore.getState().cards[epicId];
    expect(card).toBeDefined();
    const text = renderText(card);
    expect(text).toContain("Planner");
    expect(text).toContain("📋");
    expect(text).toContain("plan");
  });
});
