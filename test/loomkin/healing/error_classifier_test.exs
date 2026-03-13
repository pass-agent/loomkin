defmodule Loomkin.Healing.ErrorClassifierTest do
  use ExUnit.Case, async: true

  alias Loomkin.Healing.ErrorClassifier

  # -- classify/2: compile errors -----------------------------------------------

  describe "classify/2 compile errors" do
    test "detects CompileError" do
      result =
        ErrorClassifier.classify("** (CompileError) lib/foo.ex:10: undefined function bar/1")

      assert result.category == :compile_error
      assert result.healable == true
      assert result.severity in [:medium, :high]
    end

    test "detects undefined function" do
      result = ErrorClassifier.classify("undefined function some_func/2")
      assert result.category == :compile_error
      assert result.suggested_approach =~ "missing imports"
    end

    test "detects module not available" do
      result = ErrorClassifier.classify("module Foo.Bar is not available")
      assert result.category == :compile_error
      assert result.suggested_approach =~ "module exists"
    end

    test "detects SyntaxError with high severity" do
      result = ErrorClassifier.classify("** (SyntaxError) lib/foo.ex:5: unexpected token")
      assert result.category == :compile_error
      assert result.severity == :high
    end

    test "detects compilation error banner" do
      result = ErrorClassifier.classify("== Compilation error in file lib/foo.ex ==")
      assert result.category == :compile_error
    end

    test "extracts file path and line from error text" do
      result =
        ErrorClassifier.classify(
          "** (CompileError) lib/my_app/foo.ex:42: undefined function bar/1"
        )

      assert result.error_context[:file_path] == "lib/my_app/foo.ex"
      assert result.error_context[:line] == 42
    end
  end

  # -- classify/2: lint errors --------------------------------------------------

  describe "classify/2 lint errors" do
    test "detects mix format" do
      result = ErrorClassifier.classify("** (Mix) mix format failed for lib/foo.ex")
      assert result.category == :lint_error
      assert result.severity == :low
      assert result.healable == false
    end

    test "detects credo warnings" do
      result = ErrorClassifier.classify("[W] credo: Modules should have a @moduledoc tag")
      assert result.category == :lint_error
    end

    test "detects files not formatted" do
      result = ErrorClassifier.classify("Files were not formatted: lib/foo.ex, lib/bar.ex")
      assert result.category == :lint_error
      assert result.suggested_approach =~ "mix format"
    end
  end

  # -- classify/2: test failures ------------------------------------------------

  describe "classify/2 test failures" do
    test "detects test failures summary" do
      result = ErrorClassifier.classify("15 tests, 3 failures")
      assert result.category == :test_failure
      assert result.severity == :medium
      assert result.healable == true
    end

    test "detects high severity with many failures" do
      result = ErrorClassifier.classify("42 tests, 8 failures")
      assert result.category == :test_failure
      assert result.severity == :high
    end

    test "detects single test failure" do
      result = ErrorClassifier.classify("1 test, 1 failure")
      assert result.category == :test_failure
    end

    test "detects test FAILED pattern" do
      result = ErrorClassifier.classify("test my_function returns correct value FAILED")
      assert result.category == :test_failure
    end

    test "extracts failure count into error context" do
      result = ErrorClassifier.classify("20 tests, 3 failures")
      assert result.error_context[:test_failure_count] == 3
    end
  end

  # -- classify/2: command failures ---------------------------------------------

  describe "classify/2 command failures" do
    test "detects exit code pattern" do
      result = ErrorClassifier.classify("Exit code: 1\nstderr: something went wrong")
      assert result.category == :command_failure
      assert result.severity == :medium
    end

    test "detects non-zero exit" do
      result = ErrorClassifier.classify("Process terminated with non-zero exit code")
      assert result.category == :command_failure
    end

    test "not healable after 2 retries" do
      result = ErrorClassifier.classify("Exit code: 1", %{retry_count: 2})
      assert result.category == :command_failure
      assert result.healable == false
    end

    test "healable on first retry" do
      result = ErrorClassifier.classify("Exit code: 1", %{retry_count: 1})
      assert result.category == :command_failure
      assert result.healable == true
    end

    test "permission denied is critical severity" do
      result = ErrorClassifier.classify("Exit code: 1\npermission denied: /etc/shadow")
      assert result.category == :command_failure
      assert result.severity == :critical
    end
  end

  # -- classify/2: tool errors --------------------------------------------------

  describe "classify/2 tool errors" do
    test "detects file not found" do
      result =
        ErrorClassifier.classify("File not found: lib/missing.ex", %{tool_name: "file_read"})

      assert result.category == :tool_error
      assert result.healable == true
    end

    test "detects permission denied" do
      result =
        ErrorClassifier.classify("Permission denied: /root/secret", %{tool_name: "file_write"})

      assert result.category == :tool_error
      assert result.healable == true
    end

    test "not healable for unknown tool" do
      result =
        ErrorClassifier.classify("Error: Tool 'custom_tool' failed", %{
          tool_name: "custom_tool"
        })

      assert result.category == :tool_error
      assert result.healable == false
    end

    test "generic Error: prefix is tool_error" do
      result = ErrorClassifier.classify("Error: something unexpected happened")
      assert result.category == :tool_error
    end
  end

  # -- classify/2: resource errors ----------------------------------------------

  describe "classify/2 resource errors" do
    test "detects rate limit" do
      result = ErrorClassifier.classify("Rate limit exceeded, retry after 30s")
      assert result.category == :resource_error
      assert result.healable == false
      assert result.severity == :high
    end

    test "detects timeout exceeded" do
      result = ErrorClassifier.classify("Request timeout exceeded after 60s")
      assert result.category == :resource_error
    end

    test "detects budget exceeded" do
      result = ErrorClassifier.classify("budget exceeded for team abc-123")
      assert result.category == :resource_error
    end

    test "detects 429 too many requests" do
      result = ErrorClassifier.classify("HTTP 429: Too many requests")
      assert result.category == :resource_error
    end
  end

  # -- classify/2: unknown & edge cases -----------------------------------------

  describe "classify/2 unknown and edge cases" do
    test "unknown error text" do
      result = ErrorClassifier.classify("something completely unexpected")
      assert result.category == :unknown
      assert result.healable == false
      assert result.severity == :low
    end

    test "empty string" do
      result = ErrorClassifier.classify("")
      assert result.category == :unknown
    end

    test "non-string input returns unknown" do
      result = ErrorClassifier.classify(nil)
      assert result.category == :unknown
      assert result.healable == false
    end

    test "multi-line error text classifies correctly" do
      error = """
      Compiling 3 files (.ex)

      == Compilation error in file lib/foo.ex ==
      ** (CompileError) lib/foo.ex:15: undefined function helper/0

      Hint: Did you mean one of these?

            * helper/1
      """

      result = ErrorClassifier.classify(error)
      assert result.category == :compile_error
      assert result.error_context[:file_path] == "lib/foo.ex"
      assert result.error_context[:line] == 15
    end
  end

  # -- should_heal?/2 -----------------------------------------------------------

  describe "should_heal?/2" do
    test "returns false for non-healable classification" do
      classification = %{category: :resource_error, severity: :high, healable: false}
      refute ErrorClassifier.should_heal?(classification, %{failure_count: 5})
    end

    test "returns false for unknown errors" do
      classification = %{category: :unknown, severity: :low, healable: false}
      refute ErrorClassifier.should_heal?(classification, %{failure_count: 10})
    end

    test "returns true for compile error at threshold" do
      classification = %{category: :compile_error, severity: :medium, healable: true}
      assert ErrorClassifier.should_heal?(classification, %{failure_count: 1})
    end

    test "returns false for compile error below threshold" do
      classification = %{category: :compile_error, severity: :medium, healable: true}
      refute ErrorClassifier.should_heal?(classification, %{failure_count: 0})
    end

    test "command failure requires 2 failures" do
      classification = %{category: :command_failure, severity: :medium, healable: true}
      refute ErrorClassifier.should_heal?(classification, %{failure_count: 1})
      assert ErrorClassifier.should_heal?(classification, %{failure_count: 2})
    end

    test "returns false for low severity (lint)" do
      classification = %{category: :lint_error, severity: :low, healable: true}
      refute ErrorClassifier.should_heal?(classification, %{failure_count: 5})
    end

    test "returns false when healing is disabled for role" do
      classification = %{category: :compile_error, severity: :high, healable: true}

      refute ErrorClassifier.should_heal?(classification, %{
               failure_count: 5,
               healing_enabled: false
             })
    end

    test "returns false when healing budget is exhausted" do
      classification = %{category: :compile_error, severity: :medium, healable: true}

      refute ErrorClassifier.should_heal?(classification, %{
               failure_count: 2,
               healing_budget_remaining: 0
             })
    end

    test "returns true when healing budget is available" do
      classification = %{category: :compile_error, severity: :medium, healable: true}

      assert ErrorClassifier.should_heal?(classification, %{
               failure_count: 2,
               healing_budget_remaining: 1.5
             })
    end

    test "returns true with default agent state when healable and above threshold" do
      classification = %{category: :test_failure, severity: :medium, healable: true}
      assert ErrorClassifier.should_heal?(classification, %{failure_count: 1})
    end
  end
end
