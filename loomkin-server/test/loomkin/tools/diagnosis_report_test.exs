defmodule Loomkin.Tools.DiagnosisReportTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.DiagnosisReport

  @valid_params %{
    session_id: "heal-001",
    root_cause: "Missing null check in parser",
    affected_files: ["lib/parser.ex"],
    suggested_fix: "Add guard clause for nil input",
    severity: :high,
    confidence: 0.85
  }

  @context %{}

  describe "module existence" do
    test "module is loaded" do
      assert Code.ensure_loaded?(DiagnosisReport)
    end

    test "has Jido.Action name" do
      assert DiagnosisReport.name() == "diagnosis_report"
    end
  end

  describe "confidence validation" do
    test "rejects confidence below 0.0" do
      params = %{@valid_params | confidence: -0.1}
      assert {:error, msg} = DiagnosisReport.run(params, @context)
      assert msg =~ "confidence must be between 0.0 and 1.0"
    end

    test "rejects confidence above 1.0" do
      params = %{@valid_params | confidence: 1.5}
      assert {:error, msg} = DiagnosisReport.run(params, @context)
      assert msg =~ "confidence must be between 0.0 and 1.0"
    end

    test "accepts confidence at boundary 0.0" do
      params = %{@valid_params | confidence: 0.0}
      # Passes confidence validation — reaches orchestrator which returns :not_found
      # for the fake session_id
      result = DiagnosisReport.run(params, @context)
      assert {:error, msg} = result
      refute msg =~ "confidence must be between"
    end

    test "accepts confidence at boundary 1.0" do
      params = %{@valid_params | confidence: 1.0}
      result = DiagnosisReport.run(params, @context)
      assert {:error, msg} = result
      refute msg =~ "confidence must be between"
    end
  end

  describe "orchestrator delegation" do
    test "delegates to orchestrator and returns its error for unknown session" do
      assert {:error, "Failed to submit diagnosis: :not_found"} =
               DiagnosisReport.run(@valid_params, @context)
    end
  end

  describe "registry integration" do
    test "included in healing_tools" do
      assert DiagnosisReport in Loomkin.Tools.Registry.healing_tools()
    end

    test "findable by name" do
      assert {:ok, DiagnosisReport} = Loomkin.Tools.Registry.find("diagnosis_report")
    end

    test "included in all_with_team" do
      assert DiagnosisReport in Loomkin.Tools.Registry.all_with_team()
    end

    test "included in definitions" do
      defs = Loomkin.Tools.Registry.definitions()
      names = Enum.map(defs, & &1.name)
      assert "diagnosis_report" in names
    end
  end

  describe "param key atomization" do
    test "healing-specific keys are atomized by registry" do
      input = %{
        "session_id" => "heal-001",
        "root_cause" => "bug",
        "affected_files" => ["a.ex"],
        "suggested_fix" => "fix it",
        "verification_output" => "all pass"
      }

      result = Loomkin.Tools.Registry.atomize_keys(input)
      assert result[:session_id] == "heal-001"
      assert result[:root_cause] == "bug"
      assert result[:affected_files] == ["a.ex"]
      assert result[:suggested_fix] == "fix it"
      assert result[:verification_output] == "all pass"
    end
  end
end
