defmodule Loomkin.Vault.Validators.TemporalLanguageTest do
  use ExUnit.Case, async: true

  alias Loomkin.Vault.Validators.TemporalLanguage

  describe "validate/1" do
    test "returns :ok for non-evergreen types (meeting, checkin, decision)" do
      for type <- ~w(meeting checkin decision) do
        entry = %{entry_type: type, body: "This will happen soon.", path: "test.md"}
        assert TemporalLanguage.validate(entry) == :ok
      end
    end

    test "returns :ok for evergreen entry without temporal language" do
      entry = %{
        entry_type: "note",
        body: "Elixir uses pattern matching for control flow.",
        path: "notes/elixir.md"
      }

      assert TemporalLanguage.validate(entry) == :ok
    end

    test "detects 'will' in note body" do
      entry = %{
        entry_type: "note",
        body: "The system will handle retries.",
        path: "notes/retries.md"
      }

      assert {:warn, [violation]} = TemporalLanguage.validate(entry)
      assert violation.word == "will"
      assert violation.path == "notes/retries.md"
      assert violation.suggestion == "Use present tense or move to a decision record"
    end

    test "detects multiple violations" do
      entry = %{
        entry_type: "topic",
        body: "We will migrate soon. The system was previously unstable.",
        path: "topics/migration.md"
      }

      assert {:warn, violations} = TemporalLanguage.validate(entry)
      words = Enum.map(violations, & &1.word)
      assert "will" in words
      assert "soon" in words
      assert "was" in words
      assert "previously" in words
    end

    test "reports correct line numbers" do
      entry = %{
        entry_type: "note",
        body: "Line one is fine.\nLine two will break.\nLine three was bad.",
        path: "notes/lines.md"
      }

      assert {:warn, violations} = TemporalLanguage.validate(entry)

      will_violation = Enum.find(violations, &(&1.word == "will"))
      assert will_violation.line == 2

      was_violation = Enum.find(violations, &(&1.word == "was"))
      assert was_violation.line == 3
    end

    test "returns :ok for nil body" do
      entry = %{entry_type: "note", body: nil, path: "notes/empty.md"}
      assert TemporalLanguage.validate(entry) == :ok
    end

    test "returns :ok for missing body key" do
      entry = %{entry_type: "note", path: "notes/no-body.md"}
      assert TemporalLanguage.validate(entry) == :ok
    end

    test "returns :ok for non-evergreen entry types even with temporal words" do
      for type <- ~w(meeting checkin decision okr) do
        entry = %{
          entry_type: type,
          body: "We will soon plan the next quarter.",
          path: "records/#{type}.md"
        }

        assert TemporalLanguage.validate(entry) == :ok
      end
    end

    test "detects 'going to' phrase" do
      entry = %{
        entry_type: "project",
        body: "We are going to refactor the module.",
        path: "projects/refactor.md"
      }

      assert {:warn, violations} = TemporalLanguage.validate(entry)
      assert Enum.any?(violations, &(&1.word == "going to"))
    end

    test "detects 'next week' and similar patterns" do
      entry = %{
        entry_type: "idea",
        body: "Deploy next month after testing.",
        path: "ideas/deploy.md"
      }

      assert {:warn, violations} = TemporalLanguage.validate(entry)
      assert Enum.any?(violations, &(&1.word == "next [time]"))
    end

    test "returns :ok for entry with empty string body" do
      entry = %{entry_type: "note", body: "", path: "notes/blank.md"}
      assert TemporalLanguage.validate(entry) == :ok
    end
  end
end
