import { expect, test, beforeEach, vi } from "vitest";
import { epicCardStore } from "../epicCardStore.js";

beforeEach(() => {
  epicCardStore.getState().reset();
  vi.useRealTimers();
});

test("'created' event creates a monitoring card", () => {
  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
    epic_id: "epic-1",
  });

  const card = epicCardStore.getState().cards["epic-1"];
  expect(card).toBeDefined();
  expect(card.status).toBe("monitoring");
  expect(card.work_unit_count).toBe(0);
  expect(card.gate_progress).toEqual({});
});

test("phase_entered updates current_phase and persona", () => {
  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
    epic_id: "epic-2",
  });

  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: ["phase_entered", "research"],
    epic_id: "epic-2",
    persona: { name: "Researcher", icon: "🔬", role_blurb: "gathers context" },
  });

  const card = epicCardStore.getState().cards["epic-2"];
  expect(card.current_phase).toBe("research");
  expect(card.current_persona?.name).toBe("Researcher");
  expect(card.current_persona?.icon).toBe("🔬");
});

test("phase_entered without persona is handled gracefully", () => {
  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: ["phase_entered", "plan"],
    epic_id: "epic-3",
  });

  const card = epicCardStore.getState().cards["epic-3"];
  expect(card.current_phase).toBe("plan");
  expect(card.current_persona).toBeNull();
});

test("gate_verdict records reviewers and verdict", () => {
  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: ["gate_verdict", "plan_review", "pass", 3],
    epic_id: "epic-4",
  });

  const card = epicCardStore.getState().cards["epic-4"];
  expect(card.gate_progress.plan_review).toEqual({
    verdict: "pass",
    reviewers: 3,
  });
});

test("work_unit started events bump the unique counter", () => {
  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
    epic_id: "epic-5",
  });

  epicCardStore.getState().applyEvent({
    subtype: "work_unit",
    event: "started",
    epic_id: "epic-5",
    work_unit_id: "wu-a",
  });

  // Dupe of same WU should not double-count.
  epicCardStore.getState().applyEvent({
    subtype: "work_unit",
    event: "started",
    epic_id: "epic-5",
    work_unit_id: "wu-a",
  });

  epicCardStore.getState().applyEvent({
    subtype: "work_unit",
    event: "started",
    epic_id: "epic-5",
    work_unit_id: "wu-b",
  });

  expect(epicCardStore.getState().cards["epic-5"].work_unit_count).toBe(2);
});

test("'closed' status removes card from active list after 5s", () => {
  vi.useFakeTimers();

  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
    epic_id: "epic-6",
  });

  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "closed",
    epic_id: "epic-6",
  });

  expect(epicCardStore.getState().cards["epic-6"]?.status).toBe("closed");

  vi.advanceTimersByTime(4999);
  expect(epicCardStore.getState().cards["epic-6"]).toBeDefined();

  vi.advanceTimersByTime(2);
  expect(epicCardStore.getState().cards["epic-6"]).toBeUndefined();
});

test("'failed' event keeps card visible with failed status", () => {
  vi.useFakeTimers();

  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
    epic_id: "epic-7",
  });

  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "failed",
    epic_id: "epic-7",
  });

  vi.advanceTimersByTime(10_000);

  const card = epicCardStore.getState().cards["epic-7"];
  expect(card).toBeDefined();
  expect(card.status).toBe("failed");
});

test("'escalated' event sets escalated status and keeps card visible", () => {
  vi.useFakeTimers();

  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
    epic_id: "epic-8",
  });

  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: ["escalated"],
    epic_id: "epic-8",
  });

  vi.advanceTimersByTime(10_000);

  const card = epicCardStore.getState().cards["epic-8"];
  expect(card).toBeDefined();
  expect(card.status).toBe("escalated");
});

test("knowledge subtype is a no-op for the card store", () => {
  epicCardStore.getState().applyEvent({
    subtype: "knowledge",
    event: "fact_added",
    epic_id: "epic-9",
  });
  expect(epicCardStore.getState().cards["epic-9"]).toBeUndefined();
});

test("orchestration_diff payload records diff_summaries", () => {
  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
    epic_id: "epic-10",
  });

  epicCardStore.getState().applyEvent({
    subtype: "orchestration_diff",
    event: "diff",
    epic_id: "epic-10",
    diff: { work_unit_id: "wu-1", stats: "+12 -3" },
  });

  const card = epicCardStore.getState().cards["epic-10"];
  expect(card.diff_summaries).toHaveLength(1);
  expect(card.diff_summaries[0]).toEqual({
    work_unit_id: "wu-1",
    stats: "+12 -3",
  });
});

test("payload without epic_id is ignored", () => {
  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
  });
  expect(Object.keys(epicCardStore.getState().cards)).toHaveLength(0);
});

test("last_event_text updates on every event with persona", () => {
  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: "created",
    epic_id: "epic-11",
  });

  epicCardStore.getState().applyEvent({
    subtype: "epic",
    event: ["phase_entered", "research"],
    epic_id: "epic-11",
    persona: { name: "Researcher", icon: "🔬" },
  });

  const card = epicCardStore.getState().cards["epic-11"];
  expect(card.last_event_text).toContain("Researcher");
  expect(card.last_event_text).toContain("research");
});
