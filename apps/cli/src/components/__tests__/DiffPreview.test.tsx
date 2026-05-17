import { describe, expect, test } from "vitest";
import { DiffPreview, formatSummary, summarize, type DiffPayload } from "../DiffPreview.js";

const _ensureExported = DiffPreview;
void _ensureExported;

const sample: DiffPayload = {
  work_unit_id: "wu-1",
  sha: "abc1234567890def",
  stats: { additions: 12, deletions: 3, files: 2 },
  files: [
    { path: "lib/x.ex", additions: 10, deletions: 0 },
    { path: "lib/y.ex", additions: 2, deletions: 3 },
  ],
  patch_excerpt: "diff --git a/lib/x.ex b/lib/x.ex\n+ first line\n+ second line\n",
};

describe("DiffPreview helpers", () => {
  test("summarize extracts counts and short sha", () => {
    expect(summarize(sample)).toEqual({
      sha: "abc1234",
      additions: 12,
      deletions: 3,
      files: 2,
    });
  });

  test("summarize tolerates missing stats", () => {
    expect(summarize({} as DiffPayload)).toEqual({
      sha: "",
      additions: 0,
      deletions: 0,
      files: 0,
    });
  });

  test("formatSummary builds collapsed one-liner with pluralised file count", () => {
    const line = formatSummary(sample);
    expect(line).toContain("+12");
    expect(line).toContain("−3");
    expect(line).toContain("2 files");
    expect(line).toContain("abc1234");
  });

  test("formatSummary pluralises a single file as 'file'", () => {
    const line = formatSummary({
      sha: "deadbee",
      stats: { additions: 1, deletions: 0, files: 1 },
    });
    expect(line).toContain("1 file");
    expect(line).not.toContain("1 files");
  });

  test("formatSummary omits sha suffix when missing", () => {
    const line = formatSummary({
      stats: { additions: 1, deletions: 0, files: 1 },
    });
    expect(line).not.toContain("·");
  });

  test("DiffPreview is exported and is a function (component)", () => {
    // We cannot render an ink component in vitest without a renderer, but
    // ensuring it is exported as a function guards against accidental
    // deletions and import regressions.
    expect(typeof DiffPreview).toBe("function");
    expect(DiffPreview.length).toBeGreaterThanOrEqual(1);
  });
});
