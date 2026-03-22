defmodule Loomkin.Teams.OrchestratorModeTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Role

  describe "orchestrator_tools/0" do
    test "returns a list of tool modules" do
      tools = Role.orchestrator_tools()
      assert is_list(tools)
      assert length(tools) > 0
    end

    test "includes read-only tools" do
      tools = Role.orchestrator_tools()
      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.FileSearch in tools
      assert Loomkin.Tools.ContentSearch in tools
      assert Loomkin.Tools.DirectoryList in tools
    end

    test "includes lead/coordination tools" do
      tools = Role.orchestrator_tools()
      assert Loomkin.Tools.TeamSpawn in tools
      assert Loomkin.Tools.TeamAssign in tools
      assert Loomkin.Tools.TeamSmartAssign in tools
      assert Loomkin.Tools.TeamProgress in tools
      assert Loomkin.Tools.TeamDissolve in tools
    end

    test "includes peer and cross-team tools" do
      tools = Role.orchestrator_tools()
      assert Loomkin.Tools.PeerMessage in tools
      assert Loomkin.Tools.PeerCreateTask in tools
      assert Loomkin.Tools.PeerCompleteTask in tools
      assert Loomkin.Tools.CrossTeamQuery in tools
      assert Loomkin.Tools.ListTeams in tools
    end

    test "includes decision tools" do
      tools = Role.orchestrator_tools()
      assert Loomkin.Tools.DecisionLog in tools
      assert Loomkin.Tools.DecisionQuery in tools
      assert Loomkin.Tools.PivotDecision in tools
      assert Loomkin.Tools.GenerateWriteup in tools
    end

    test "includes context retrieval tools" do
      tools = Role.orchestrator_tools()
      assert Loomkin.Tools.ContextRetrieve in tools
      assert Loomkin.Tools.SearchKeepers in tools
    end

    test "includes conversation and collaboration tools" do
      tools = Role.orchestrator_tools()
      assert Loomkin.Tools.SpawnConversation in tools
      assert Loomkin.Tools.CollectiveDecision in tools
      assert Loomkin.Tools.AskUser in tools
    end

    test "excludes write tools" do
      tools = Role.orchestrator_tools()
      refute Loomkin.Tools.FileWrite in tools
      refute Loomkin.Tools.FileEdit in tools
    end

    test "excludes execution tools" do
      tools = Role.orchestrator_tools()
      refute Loomkin.Tools.Shell in tools
      refute Loomkin.Tools.Git in tools
    end

    test "excludes SubAgent and LspDiagnostics" do
      tools = Role.orchestrator_tools()
      refute Loomkin.Tools.SubAgent in tools
      refute Loomkin.Tools.LspDiagnostics in tools
    end
  end

  describe "orchestrator_prompt_addition/0" do
    test "returns orchestrator guidance text" do
      prompt = Role.orchestrator_prompt_addition()
      assert is_binary(prompt)
      assert prompt =~ "orchestrator mode"
      assert prompt =~ "READ files"
      assert prompt =~ "cannot EDIT"
      assert prompt =~ "Delegate"
      assert prompt =~ "spawn or assign a specialist"
      assert prompt =~ "peer_complete_task"
    end
  end

  describe "lead role still has all tools by default" do
    test "lead role includes write and exec tools" do
      {:ok, %Role{tools: tools}} = Role.get(:lead)
      assert Loomkin.Tools.FileWrite in tools
      assert Loomkin.Tools.FileEdit in tools
      assert Loomkin.Tools.Shell in tools
      assert Loomkin.Tools.Git in tools
    end
  end
end
