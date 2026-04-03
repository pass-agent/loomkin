defmodule Loomkin.Tools.AcceptanceChecksTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.AcceptanceChecks

  describe "module existence" do
    test "module is loaded" do
      assert Code.ensure_loaded?(AcceptanceChecks)
    end

    test "has Jido.Action name" do
      assert AcceptanceChecks.name() == "acceptance_checks"
    end

    test "exports run/2" do
      Code.ensure_loaded!(AcceptanceChecks)
      assert function_exported?(AcceptanceChecks, :run, 2)
    end
  end

  describe "syntax check" do
    test "passes for valid project" do
      project_path = Path.expand("../../..", __DIR__)

      result =
        AcceptanceChecks.run(
          %{check_type: :syntax, task_id: "test-task-1"},
          %{project_path: project_path}
        )

      assert {:ok, %{check_type: :syntax, passed: passed, result: result_text}} = result
      # Project should compile fine
      assert is_boolean(passed)
      assert is_binary(result_text)
    end
  end

  describe "lint check" do
    test "returns structured result" do
      project_path = Path.expand("../../..", __DIR__)

      result =
        AcceptanceChecks.run(
          %{check_type: :lint, task_id: "test-task-2"},
          %{project_path: project_path}
        )

      assert {:ok, %{check_type: :lint, passed: passed, result: result_text}} = result
      assert is_boolean(passed)
      assert is_binary(result_text)
    end
  end

  describe "spec check" do
    test "skips when no spec_description provided" do
      result =
        AcceptanceChecks.run(
          %{check_type: :spec, task_id: "test-task-3"},
          %{project_path: "/tmp"}
        )

      assert {:ok, %{check_type: :spec, passed: true, result: result_text}} = result
      assert result_text =~ "SKIPPED"
    end

    test "returns manual review when spec provided" do
      result =
        AcceptanceChecks.run(
          %{check_type: :spec, task_id: "test-task-4", spec_description: "Must handle nil input"},
          %{project_path: "/tmp"}
        )

      assert {:ok, %{check_type: :spec, passed: true, result: result_text}} = result
      assert result_text =~ "MANUAL"
      assert result_text =~ "Must handle nil input"
    end
  end

  describe "param key atomization" do
    test "check_type and spec_description are atomized by registry" do
      input = %{
        "check_type" => "syntax",
        "task_id" => "t-1",
        "spec_description" => "some spec",
        "files_changed" => ["lib/foo.ex"]
      }

      result = Loomkin.Tools.Registry.atomize_keys(input)
      assert result[:check_type] == "syntax"
      assert result[:task_id] == "t-1"
      assert result[:spec_description] == "some spec"
      assert result[:files_changed] == ["lib/foo.ex"]
    end
  end
end
