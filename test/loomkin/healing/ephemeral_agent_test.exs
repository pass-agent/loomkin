defmodule Loomkin.Healing.EphemeralAgentTest do
  use ExUnit.Case, async: true

  alias Loomkin.Healing.EphemeralAgent

  describe "tools_for/1" do
    test "diagnostician tools are read-only plus DiagnosisReport" do
      tools = EphemeralAgent.tools_for(:diagnostician)

      assert Loomkin.Tools.LspDiagnostics in tools
      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.ContentSearch in tools
      assert Loomkin.Tools.FileSearch in tools
      assert Loomkin.Tools.DirectoryList in tools
      assert Loomkin.Tools.Shell in tools
      assert Loomkin.Tools.DiagnosisReport in tools

      # Must NOT include write tools
      refute Loomkin.Tools.FileEdit in tools
      refute Loomkin.Tools.FileWrite in tools
      refute Loomkin.Tools.Git in tools
      refute Loomkin.Tools.FixConfirmation in tools
    end

    test "fixer tools include write-capable tools plus FixConfirmation" do
      tools = EphemeralAgent.tools_for(:fixer)

      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.FileEdit in tools
      assert Loomkin.Tools.FileWrite in tools
      assert Loomkin.Tools.Shell in tools
      assert Loomkin.Tools.Git in tools
      assert Loomkin.Tools.LspDiagnostics in tools
      assert Loomkin.Tools.FixConfirmation in tools

      # Must NOT include diagnosis tool
      refute Loomkin.Tools.DiagnosisReport in tools
    end

    test "diagnostician has exactly 7 tools" do
      assert length(EphemeralAgent.tools_for(:diagnostician)) == 7
    end

    test "fixer has exactly 7 tools" do
      assert length(EphemeralAgent.tools_for(:fixer)) == 7
    end
  end

  describe "module existence" do
    test "EphemeralAgent module is loaded" do
      assert Code.ensure_loaded?(EphemeralAgent)
    end

    test "exports start/1" do
      Code.ensure_loaded!(EphemeralAgent)
      assert function_exported?(EphemeralAgent, :start, 1)
    end

    test "exports tools_for/1" do
      Code.ensure_loaded!(EphemeralAgent)
      assert function_exported?(EphemeralAgent, :tools_for, 1)
    end
  end

  describe "tool set constraints" do
    test "diagnostician cannot write files" do
      write_tools = [
        Loomkin.Tools.FileEdit,
        Loomkin.Tools.FileWrite,
        Loomkin.Tools.Git
      ]

      diag_tools = EphemeralAgent.tools_for(:diagnostician)

      for tool <- write_tools do
        refute tool in diag_tools,
               "Diagnostician should not have write tool #{inspect(tool)}"
      end
    end

    test "fixer cannot submit diagnosis" do
      refute Loomkin.Tools.DiagnosisReport in EphemeralAgent.tools_for(:fixer),
             "Fixer should not have DiagnosisReport tool"
    end

    test "both roles share FileRead and LspDiagnostics" do
      diag = EphemeralAgent.tools_for(:diagnostician)
      fixer = EphemeralAgent.tools_for(:fixer)

      for tool <- [Loomkin.Tools.FileRead, Loomkin.Tools.LspDiagnostics] do
        assert tool in diag
        assert tool in fixer
      end
    end
  end
end
