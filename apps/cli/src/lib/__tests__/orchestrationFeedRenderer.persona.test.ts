import { describe, expect, test } from "vitest";
import { formatOrchestrationPhase } from "../orchestrationFeedRenderer.js";

describe("formatOrchestrationPhase — persona enrichment", () => {
  test("persona prepends `<icon> <name>: ` and drops the [epic:..] scope", () => {
    const out = formatOrchestrationPhase({
      subtype: "epic",
      epic_id: "abc123def456",
      event: ["phase_entered", "research"],
      persona: { name: "Researcher", icon: "🔬" },
    });
    expect(out).toBe("🔬 Researcher: ⇢ research");
    expect(out).not.toContain("[epic:");
  });

  test("persona on a work_unit completed event reads `Committer: ✓ completed`", () => {
    const out = formatOrchestrationPhase({
      subtype: "work_unit",
      work_unit_id: "wuabcdefg",
      event: "completed",
      persona: { name: "Committer", icon: "✅" },
    });
    expect(out).toBe("✅ Committer: ✓ completed");
    expect(out).not.toContain("[wu:");
  });

  test("persona on a gate_verdict shows the council name", () => {
    const out = formatOrchestrationPhase({
      subtype: "gate",
      epic_id: "abc",
      event: ["gate_verdict", "plan_review", "pass", 3],
      persona: { name: "Plan Council", icon: "⚖️" },
    });
    expect(out?.startsWith("⚖️ Plan Council: ")).toBe(true);
    expect(out).toContain("✓ plan_review");
    expect(out).toContain("3 reviewers");
  });

  test("persona on a knowledge event reads `Curator: ⇡ knowledge fact added`", () => {
    const out = formatOrchestrationPhase({
      subtype: "knowledge",
      event: undefined,
      persona: { name: "Curator", icon: "📚" },
    });
    expect(out).toBe("📚 Curator: ⇡ knowledge fact added");
  });

  test("persona on retry surfaces the Coder", () => {
    const out = formatOrchestrationPhase({
      subtype: "work_unit",
      work_unit_id: "wux",
      event: ["retry", "implement", "validator said no"],
      persona: { name: "Coder", icon: "🛠" },
    });
    expect(out).toBe("🛠 Coder: ↻ retry → implement");
  });

  test("missing persona keeps the legacy [epic:..] scope (backward compatible)", () => {
    const out = formatOrchestrationPhase({
      subtype: "epic",
      epic_id: "abc123def456",
      event: ["phase_entered", "plan_review"],
    });
    expect(out).toBe("[epic:abc123] ⇢ plan_review");
  });

  test("missing persona on completed work_unit keeps [wu:..] prefix", () => {
    const out = formatOrchestrationPhase({
      subtype: "work_unit",
      work_unit_id: "wuabcdefg",
      event: "completed",
    });
    expect(out).toBe("[wu:wuabcd] ✓ completed");
  });

  test("persona on an unknown tuple event still returns null (we never invent text)", () => {
    const out = formatOrchestrationPhase({
      subtype: "epic",
      epic_id: "abc",
      event: ["totally_unknown_tag"],
      persona: { name: "System", icon: "•" },
    });
    expect(out).toBeNull();
  });
});
