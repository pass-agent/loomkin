defmodule Loomkin.ProjectRulesTest do
  use ExUnit.Case, async: true

  alias Loomkin.ProjectRules

  describe "load/1" do
    @tag :tmp_dir
    test "returns empty rules when no LOOMKIN.md exists", %{tmp_dir: tmp_dir} do
      assert {:ok, rules} = ProjectRules.load(tmp_dir)
      assert rules.raw == ""
      assert rules.instructions == ""
      assert rules.rules == []
      assert rules.allowed_ops == %{}
      assert rules.denied_ops == []
    end

    @tag :tmp_dir
    test "loads LOOMKIN.md file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "LOOMKIN.md"), "Hello world")
      assert {:ok, rules} = ProjectRules.load(tmp_dir)
      assert rules.raw == "Hello world"
    end

    @tag :tmp_dir
    test "loads .loomkin.md file as fallback", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".loomkin.md"), "Hidden rules")
      assert {:ok, rules} = ProjectRules.load(tmp_dir)
      assert rules.raw == "Hidden rules"
    end

    @tag :tmp_dir
    test "prefers LOOMKIN.md over .loomkin.md", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "LOOMKIN.md"), "Primary")
      File.write!(Path.join(tmp_dir, ".loomkin.md"), "Secondary")
      assert {:ok, rules} = ProjectRules.load(tmp_dir)
      assert rules.raw == "Primary"
    end

    @tag :tmp_dir
    test "parses rules section", %{tmp_dir: tmp_dir} do
      content = """
      General instructions here.

      ## Rules
      - Always write tests
      - Use pattern matching
      * Prefer pipes over nesting
      """

      File.write!(Path.join(tmp_dir, "LOOMKIN.md"), content)
      assert {:ok, rules} = ProjectRules.load(tmp_dir)

      assert "Always write tests" in rules.rules
      assert "Use pattern matching" in rules.rules
      assert "Prefer pipes over nesting" in rules.rules
      assert length(rules.rules) == 3
    end

    @tag :tmp_dir
    test "parses allowed operations", %{tmp_dir: tmp_dir} do
      content = """
      ## Allowed Operations
      - Shell: `mix *`, `git *`
      - File: `lib/**/*.ex`, `test/**/*.exs`
      """

      File.write!(Path.join(tmp_dir, "LOOMKIN.md"), content)
      assert {:ok, rules} = ProjectRules.load(tmp_dir)

      assert rules.allowed_ops["shell"] == ["mix *", "git *"]
      assert rules.allowed_ops["file"] == ["lib/**/*.ex", "test/**/*.exs"]
    end

    @tag :tmp_dir
    test "parses denied operations", %{tmp_dir: tmp_dir} do
      content = """
      ## Denied Operations
      - Never delete production data
      - Do not modify .env files
      """

      File.write!(Path.join(tmp_dir, "LOOMKIN.md"), content)
      assert {:ok, rules} = ProjectRules.load(tmp_dir)

      assert "Never delete production data" in rules.denied_ops
      assert "Do not modify .env files" in rules.denied_ops
    end

    @tag :tmp_dir
    test "extracts general instructions from unrecognized sections", %{tmp_dir: tmp_dir} do
      content = """
      This is preamble text.

      ## Architecture
      We use Phoenix LiveView.

      ## Rules
      - Write clean code
      """

      File.write!(Path.join(tmp_dir, "LOOMKIN.md"), content)
      assert {:ok, rules} = ProjectRules.load(tmp_dir)

      assert rules.instructions =~ "This is preamble text."
      assert rules.instructions =~ "Architecture"
      assert rules.instructions =~ "Phoenix LiveView"
      # Rules section should NOT be in instructions
      refute rules.instructions =~ "Write clean code"
    end

    @tag :tmp_dir
    test "handles full document with all sections", %{tmp_dir: tmp_dir} do
      content = """
      You are a coding assistant for the Loomkin project.

      ## Context
      Loomkin is an AI coding agent built in Elixir.

      ## Rules
      - Always read before writing
      - Prefer small changes

      ## Allowed Operations
      - Shell: `mix test`, `mix compile`

      ## Denied Operations
      - Never push to main
      """

      File.write!(Path.join(tmp_dir, "LOOMKIN.md"), content)
      assert {:ok, rules} = ProjectRules.load(tmp_dir)

      assert rules.instructions =~ "coding assistant"
      assert rules.instructions =~ "Loomkin is an AI coding agent"
      assert length(rules.rules) == 2
      assert rules.allowed_ops["shell"] == ["mix test", "mix compile"]
      assert length(rules.denied_ops) == 1
    end
  end

  describe "format_for_prompt/1" do
    test "returns empty string for empty rules" do
      rules = %{raw: "", instructions: "", rules: [], allowed_ops: %{}, denied_ops: []}
      assert ProjectRules.format_for_prompt(rules) == ""
    end

    test "includes instructions" do
      rules = %{
        raw: "",
        instructions: "Be careful with code changes.",
        rules: [],
        allowed_ops: %{},
        denied_ops: []
      }

      result = ProjectRules.format_for_prompt(rules)
      assert result =~ "## Project Instructions"
      assert result =~ "Be careful with code changes."
    end

    test "includes rules as list" do
      rules = %{
        raw: "",
        instructions: "",
        rules: ["Write tests", "Use dialyzer"],
        allowed_ops: %{},
        denied_ops: []
      }

      result = ProjectRules.format_for_prompt(rules)
      assert result =~ "## Rules"
      assert result =~ "- Write tests"
      assert result =~ "- Use dialyzer"
    end

    test "includes all sections" do
      rules = %{
        raw: "",
        instructions: "General info",
        rules: ["Rule one"],
        allowed_ops: %{"shell" => ["mix *"]},
        denied_ops: ["No deletions"]
      }

      result = ProjectRules.format_for_prompt(rules)
      assert result =~ "## Project Instructions"
      assert result =~ "## Rules"
      assert result =~ "## Allowed Operations"
      assert result =~ "## Denied Operations"
    end
  end

  describe "find_rules_file/1" do
    @tag :tmp_dir
    test "returns nil when no file exists", %{tmp_dir: tmp_dir} do
      assert ProjectRules.find_rules_file(tmp_dir) == nil
    end

    @tag :tmp_dir
    test "finds LOOMKIN.md", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "LOOMKIN.md")
      File.write!(path, "")
      assert ProjectRules.find_rules_file(tmp_dir) == path
    end

    @tag :tmp_dir
    test "finds .loomkin.md when LOOMKIN.md absent", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, ".loomkin.md")
      File.write!(path, "")
      assert ProjectRules.find_rules_file(tmp_dir) == path
    end
  end
end
