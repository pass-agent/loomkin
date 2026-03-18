defmodule Loomkin.Utils.TaskSummaryTest do
  use ExUnit.Case, async: true

  alias Loomkin.Utils.TaskSummary

  @full_attrs %{
    result: "Implemented authentication module with JWT token support and session management",
    actions_taken: ["Created auth module", "Added JWT dependency", "Wrote migration"],
    discoveries: ["Existing session code uses deprecated API", "Token expiry is hardcoded"],
    files_changed: ["lib/app/auth.ex", "lib/app/auth/token.ex", "test/app/auth_test.exs"],
    decisions_made: ["Used Guardian over custom JWT", "Chose 24h token expiry"],
    open_questions: ["Should we support refresh tokens?"]
  }

  @minimal_attrs %{
    result: "Fixed the bug in the login form validation logic",
    actions_taken: ["Patched validation function"],
    discoveries: [],
    files_changed: ["lib/app/login.ex"],
    decisions_made: [],
    open_questions: []
  }

  @empty_attrs %{
    result: "",
    actions_taken: [],
    discoveries: [],
    files_changed: [],
    decisions_made: [],
    open_questions: []
  }

  describe "extract_metrics/1" do
    test "extracts correct counts from full completion" do
      metrics = TaskSummary.extract_metrics(@full_attrs)

      assert metrics.action_count == 3
      assert metrics.discovery_count == 2
      assert metrics.file_count == 3
      assert metrics.decision_count == 2
      assert metrics.open_question_count == 1
      assert metrics.artifact_count == 8
      assert metrics.result_length > 20
      assert metrics.quality_score > 0.0
    end

    test "handles empty completion" do
      metrics = TaskSummary.extract_metrics(@empty_attrs)

      assert metrics.artifact_count == 0
      assert metrics.action_count == 0
      assert metrics.file_count == 0
      assert metrics.quality_score == 0.0
    end

    test "handles missing keys gracefully" do
      metrics = TaskSummary.extract_metrics(%{})

      assert metrics.artifact_count == 0
      assert metrics.result_length == 0
      assert metrics.quality_score == 0.0
    end
  end

  describe "quality_label/1" do
    test "returns :excellent for rich completions" do
      assert TaskSummary.quality_label(@full_attrs) == :excellent
    end

    test "returns :good for decent completions" do
      assert TaskSummary.quality_label(@minimal_attrs) in [:good, :minimal]
    end

    test "returns :empty for empty completions" do
      assert TaskSummary.quality_label(@empty_attrs) == :empty
    end

    test "returns :poor for result-only completion" do
      attrs = %{@empty_attrs | result: "Did something small"}
      label = TaskSummary.quality_label(attrs)
      assert label in [:poor, :empty]
    end
  end

  describe "format_completion/1" do
    test "includes all sections for full completion" do
      formatted = TaskSummary.format_completion(@full_attrs)

      assert formatted =~ "## Result"
      assert formatted =~ "authentication"
      assert formatted =~ "### Actions Taken"
      assert formatted =~ "Created auth module"
      assert formatted =~ "### Discoveries"
      assert formatted =~ "deprecated API"
      assert formatted =~ "### Files Changed"
      assert formatted =~ "lib/app/auth.ex"
      assert formatted =~ "### Decisions Made"
      assert formatted =~ "Guardian"
      assert formatted =~ "### Open Questions"
      assert formatted =~ "refresh tokens"
      assert formatted =~ "Artifacts:"
      assert formatted =~ "Quality:"
    end

    test "omits empty sections" do
      formatted = TaskSummary.format_completion(@minimal_attrs)

      assert formatted =~ "### Actions Taken"
      assert formatted =~ "### Files Changed"
      refute formatted =~ "### Discoveries"
      refute formatted =~ "### Decisions Made"
      refute formatted =~ "### Open Questions"
    end

    test "handles empty attrs without crashing" do
      formatted = TaskSummary.format_completion(@empty_attrs)

      assert is_binary(formatted)
      assert formatted =~ "Artifacts: 0"
    end
  end

  describe "group_files_by_directory/1" do
    test "groups files correctly" do
      files = [
        "lib/app/auth/token.ex",
        "lib/app/auth/session.ex",
        "test/app/auth/token_test.exs",
        "config/config.exs"
      ]

      grouped = TaskSummary.group_files_by_directory(files)

      assert grouped["lib/app/auth"] == ["token.ex", "session.ex"]
      assert grouped["test/app/auth"] == ["token_test.exs"]
      assert grouped["config"] == ["config.exs"]
    end

    test "handles empty list" do
      assert TaskSummary.group_files_by_directory([]) == %{}
    end

    test "filters nil and empty strings" do
      grouped = TaskSummary.group_files_by_directory([nil, "", "lib/app.ex"])
      assert map_size(grouped) == 1
      assert grouped["lib"] == ["app.ex"]
    end
  end

  describe "one_line_summary/1" do
    test "produces a compact summary" do
      summary = TaskSummary.one_line_summary(@full_attrs)

      assert summary =~ "[excellent]"
      assert summary =~ "3 files"
      assert summary =~ "3 actions"
      assert summary =~ "2 discoveries"
    end

    test "truncates long results" do
      long_result = String.duplicate("x", 200)
      attrs = %{@full_attrs | result: long_result}
      summary = TaskSummary.one_line_summary(attrs)

      assert String.length(summary) < 300
      assert summary =~ "..."
    end
  end

  describe "merge_completions/1" do
    test "merges multiple completions" do
      comp1 = %{
        result: "First result",
        actions_taken: ["action 1"],
        discoveries: ["discovery 1"],
        files_changed: ["file_a.ex"],
        decisions_made: ["decision 1"],
        open_questions: ["question 1"]
      }

      comp2 = %{
        result: "Second result",
        actions_taken: ["action 2"],
        discoveries: ["discovery 2"],
        files_changed: ["file_b.ex", "file_a.ex"],
        decisions_made: [],
        open_questions: []
      }

      merged = TaskSummary.merge_completions([comp1, comp2])

      assert merged.result =~ "First result"
      assert merged.result =~ "Second result"
      assert length(merged.actions_taken) == 2
      assert length(merged.discoveries) == 2
      # Deduplicates files
      assert length(merged.files_changed) == 2
      assert "file_a.ex" in merged.files_changed
      assert "file_b.ex" in merged.files_changed
      assert length(merged.decisions_made) == 1
      assert length(merged.open_questions) == 1
    end

    test "handles empty list" do
      merged = TaskSummary.merge_completions([])

      assert merged.result == ""
      assert merged.actions_taken == []
      assert merged.files_changed == []
    end
  end
end
