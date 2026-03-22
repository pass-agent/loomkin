defmodule Loomkin.Tools.FixConfirmationTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.FixConfirmation

  @verified_params %{
    session_id: "heal-001",
    description: "Added null check to parser",
    files_changed: ["lib/parser.ex"],
    verified: true,
    verification_output: "All tests pass"
  }

  @unverified_params %{
    session_id: "heal-001",
    description: "Attempted fix but tests still fail",
    files_changed: ["lib/parser.ex"],
    verified: false
  }

  @context %{}

  describe "module existence" do
    test "module is loaded" do
      assert Code.ensure_loaded?(FixConfirmation)
    end

    test "has Jido.Action name" do
      assert FixConfirmation.name() == "fix_confirmation"
    end
  end

  describe "verified fix path" do
    test "delegates to orchestrator confirm_fix for verified fix" do
      assert {:error, "Failed to confirm fix: :not_found"} =
               FixConfirmation.run(@verified_params, @context)
    end
  end

  describe "unverified fix path" do
    test "delegates to orchestrator fix_failed for unverified fix" do
      assert {:error, "Failed to report fix failure: :not_found"} =
               FixConfirmation.run(@unverified_params, @context)
    end
  end

  describe "registry integration" do
    test "included in healing_tools" do
      assert FixConfirmation in Loomkin.Tools.Registry.healing_tools()
    end

    test "findable by name" do
      assert {:ok, FixConfirmation} = Loomkin.Tools.Registry.find("fix_confirmation")
    end

    test "included in all_with_team" do
      assert FixConfirmation in Loomkin.Tools.Registry.all_with_team()
    end

    test "included in definitions" do
      defs = Loomkin.Tools.Registry.definitions()
      names = Enum.map(defs, & &1.name)
      assert "fix_confirmation" in names
    end
  end

  describe "param key atomization" do
    test "healing-specific keys are atomized by registry" do
      input = %{
        "session_id" => "heal-001",
        "files_changed" => ["a.ex"],
        "verified" => true
      }

      result = Loomkin.Tools.Registry.atomize_keys(input)
      assert result[:session_id] == "heal-001"
      assert result[:files_changed] == ["a.ex"]
      assert result[:verified] == true
    end
  end
end
