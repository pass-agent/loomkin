import { describe, expect, test } from "vitest";
import { formatOrchestrationPhase } from "../orchestrationFeedRenderer.js";

describe("formatOrchestrationPhase", () => {
  test("phase_entered tuple becomes ⇢ <phase>", () => {
    const out = formatOrchestrationPhase({
      subtype: "epic",
      epic_id: "abc123def456",
      event: ["phase_entered", "plan_review"],
    });
    expect(out).toBe("[epic:abc123] ⇢ plan_review");
  });

  test("gate_verdict pass becomes ✓ with count", () => {
    const out = formatOrchestrationPhase({
      subtype: "epic",
      epic_id: "abc123def456",
      event: ["gate_verdict", "plan_review", "pass", 3],
    });
    expect(out).toContain("✓ plan_review");
    expect(out).toContain("3 reviewers");
  });

  test("gate_verdict fail uses ✗", () => {
    const out = formatOrchestrationPhase({
      subtype: "epic",
      epic_id: "abc123def456",
      event: ["gate_verdict", "design_review", "fail", 1],
    });
    expect(out).toContain("✗ design_review");
    expect(out).toContain("1 reviewer");
  });

  test("escalated event is highlighted", () => {
    const out = formatOrchestrationPhase({
      subtype: "epic",
      epic_id: "abc",
      event: ["escalated"],
    });
    expect(out).toContain("▲ escalated");
  });

  test("work_unit scope uses wu: prefix", () => {
    const out = formatOrchestrationPhase({
      subtype: "work_unit",
      work_unit_id: "wuabcdefg",
      event: "completed",
    });
    expect(out).toBe("[wu:wuabcd] ✓ completed");
  });

  test("commit_done shows short sha", () => {
    const out = formatOrchestrationPhase({
      subtype: "work_unit",
      work_unit_id: "wuabcdefg",
      event: ["commit_done", "abc1234567890def"],
    });
    expect(out).toContain("✓ commit abc123456789");
  });

  test("knowledge subtype shows fact added", () => {
    const out = formatOrchestrationPhase({
      subtype: "knowledge",
      event: undefined,
    });
    expect(out).toBe("[knowledge] ⇡ knowledge fact added");
  });

  test("unknown event shape returns null (don't pollute the feed)", () => {
    const out = formatOrchestrationPhase({
      subtype: "epic",
      event: { random: "object" } as unknown as string,
    });
    expect(out).toBeNull();
  });

  test("retry event uses ↻", () => {
    const out = formatOrchestrationPhase({
      subtype: "work_unit",
      work_unit_id: "wux",
      event: ["retry", "implement", "validator said no"],
    });
    expect(out).toContain("↻ retry");
  });
});
