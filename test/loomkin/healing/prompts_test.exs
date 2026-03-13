defmodule Loomkin.Healing.PromptsTest do
  use ExUnit.Case, async: true

  alias Loomkin.Healing.Prompts

  describe "diagnostician/1" do
    test "includes error classification context" do
      prompt =
        Prompts.diagnostician(
          session_id: "heal-001",
          classification: %{
            category: :compile_error,
            severity: :high,
            suggested_approach: "Check imports"
          },
          error_context: %{
            error_text: "undefined function foo/1",
            tool_name: "shell",
            file_path: "lib/bar.ex"
          },
          max_iterations: 5
        )

      assert prompt =~ "Diagnostician agent"
      assert prompt =~ "compile_error"
      assert prompt =~ "high"
      assert prompt =~ "Check imports"
      assert prompt =~ "undefined function foo/1"
      assert prompt =~ "shell"
      assert prompt =~ "lib/bar.ex"
      assert prompt =~ "5 iterations"
      assert prompt =~ "heal-001"
      assert prompt =~ "diagnosis_report"
    end

    test "includes retry context when provided" do
      prompt =
        Prompts.diagnostician(
          session_id: "heal-002",
          classification: %{category: :test_failure},
          retry_context: "Previous fix added wrong import"
        )

      assert prompt =~ "PREVIOUS FIX ATTEMPT FAILED"
      assert prompt =~ "Previous fix added wrong import"
    end

    test "omits retry section when no retry_context" do
      prompt =
        Prompts.diagnostician(
          session_id: "heal-003",
          classification: %{category: :lint_error}
        )

      refute prompt =~ "PREVIOUS FIX ATTEMPT FAILED"
    end

    test "uses defaults for missing opts" do
      prompt = Prompts.diagnostician(session_id: "heal-004")

      assert prompt =~ "unknown"
      assert prompt =~ "7 iterations"
      assert prompt =~ "heal-004"
    end
  end

  describe "fixer/1" do
    test "includes diagnosis context" do
      prompt =
        Prompts.fixer(
          session_id: "heal-001",
          diagnosis: %{
            root_cause: "Missing import of Enum module",
            affected_files: ["lib/foo.ex", "lib/bar.ex"],
            suggested_fix: "Add alias Enum at top of module",
            severity: :medium,
            confidence: 0.9
          },
          classification: %{category: :compile_error},
          max_iterations: 8
        )

      assert prompt =~ "Fixer agent"
      assert prompt =~ "Missing import of Enum module"
      assert prompt =~ "lib/foo.ex, lib/bar.ex"
      assert prompt =~ "Add alias Enum at top of module"
      assert prompt =~ "medium"
      assert prompt =~ "0.9"
      assert prompt =~ "8 iterations"
      assert prompt =~ "heal-001"
      assert prompt =~ "fix_confirmation"
    end

    test "uses defaults for missing opts" do
      prompt = Prompts.fixer(session_id: "heal-005")

      assert prompt =~ "See diagnosis"
      assert prompt =~ "7 iterations"
      assert prompt =~ "heal-005"
    end
  end
end
