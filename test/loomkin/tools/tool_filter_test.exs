defmodule Loomkin.Tools.ToolFilterTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.ToolFilter

  describe "tools_for_role/1" do
    test "returns tools for researcher role" do
      {:ok, tools} = ToolFilter.tools_for_role(:researcher)

      # Read-only tools present
      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.FileSearch in tools
      assert Loomkin.Tools.ContentSearch in tools
      assert Loomkin.Tools.DirectoryList in tools

      # Decision tools present
      assert Loomkin.Tools.DecisionLog in tools
      assert Loomkin.Tools.DecisionQuery in tools

      # Peer tools present
      assert Loomkin.Tools.PeerMessage in tools
      assert Loomkin.Tools.PeerCompleteTask in tools
      assert Loomkin.Tools.ContextRetrieve in tools

      # Write tools NOT present — researchers must be read-only
      refute Loomkin.Tools.FileWrite in tools
      refute Loomkin.Tools.FileEdit in tools

      # Exec tools NOT present
      refute Loomkin.Tools.Shell in tools
      refute Loomkin.Tools.Git in tools

      # Investigation tools NOT present — researchers shouldn't use SubAgent
      refute Loomkin.Tools.SubAgent in tools
      refute Loomkin.Tools.LspDiagnostics in tools

      # Lead tools NOT present
      refute Loomkin.Tools.TeamSpawn in tools
      refute Loomkin.Tools.TeamAssign in tools
    end

    test "returns tools for coder role" do
      {:ok, tools} = ToolFilter.tools_for_role(:coder)

      # Read + write + exec tools present
      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.FileWrite in tools
      assert Loomkin.Tools.FileEdit in tools
      assert Loomkin.Tools.Shell in tools
      assert Loomkin.Tools.Git in tools

      # Peer + decision tools present
      assert Loomkin.Tools.PeerMessage in tools
      assert Loomkin.Tools.DecisionLog in tools

      # Investigation tools NOT present — coders shouldn't use SubAgent
      refute Loomkin.Tools.SubAgent in tools

      # Lead tools NOT present
      refute Loomkin.Tools.TeamSpawn in tools
    end

    test "returns tools for reviewer role" do
      {:ok, tools} = ToolFilter.tools_for_role(:reviewer)

      # Read + exec tools present (shell for linters/compiler)
      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.Shell in tools
      assert Loomkin.Tools.Git in tools

      # Write tools NOT present — reviewers observe, don't write
      refute Loomkin.Tools.FileWrite in tools
      refute Loomkin.Tools.FileEdit in tools

      # Investigation tools NOT present
      refute Loomkin.Tools.SubAgent in tools
    end

    test "returns tools for tester role" do
      {:ok, tools} = ToolFilter.tools_for_role(:tester)

      # Same as reviewer: read + exec, no write
      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.Shell in tools

      refute Loomkin.Tools.FileWrite in tools
      refute Loomkin.Tools.FileEdit in tools
    end

    test "returns tools for lead role" do
      {:ok, tools} = ToolFilter.tools_for_role(:lead)

      # Lead gets everything
      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.FileWrite in tools
      assert Loomkin.Tools.Shell in tools
      assert Loomkin.Tools.TeamSpawn in tools
      assert Loomkin.Tools.TeamAssign in tools
      assert Loomkin.Tools.SubAgent in tools
    end

    test "returns tools for weaver role" do
      {:ok, tools} = ToolFilter.tools_for_role(:weaver)

      # Coordination tools present
      assert Loomkin.Tools.PeerMessage in tools
      assert Loomkin.Tools.ContextRetrieve in tools
      assert Loomkin.Tools.DecisionLog in tools
      assert Loomkin.Tools.TeamProgress in tools
      assert Loomkin.Tools.CollectiveDecision in tools
      assert Loomkin.Tools.MergeGraph in tools

      # No read/write/exec tools
      refute Loomkin.Tools.FileRead in tools
      refute Loomkin.Tools.FileWrite in tools
      refute Loomkin.Tools.Shell in tools
      refute Loomkin.Tools.SubAgent in tools
    end

    test "returns tools for concierge role" do
      {:ok, tools} = ToolFilter.tools_for_role(:concierge)

      # Concierge gets everything (like lead)
      assert Loomkin.Tools.FileRead in tools
      assert Loomkin.Tools.FileWrite in tools
      assert Loomkin.Tools.Shell in tools
      assert Loomkin.Tools.TeamSpawn in tools
      assert Loomkin.Tools.SubAgent in tools
    end

    test "returns error for unknown role" do
      assert {:error, :unknown_role} = ToolFilter.tools_for_role(:nonexistent)
    end
  end

  describe "allowed?/2" do
    test "researcher cannot use file_write" do
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.FileWrite)
    end

    test "researcher cannot use file_edit" do
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.FileEdit)
    end

    test "researcher cannot use shell" do
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.Shell)
    end

    test "researcher cannot use git" do
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.Git)
    end

    test "researcher cannot use sub_agent" do
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.SubAgent)
    end

    test "researcher can use file_read" do
      assert ToolFilter.allowed?(:researcher, Loomkin.Tools.FileRead)
    end

    test "researcher can use content_search" do
      assert ToolFilter.allowed?(:researcher, Loomkin.Tools.ContentSearch)
    end

    test "researcher can use peer tools" do
      assert ToolFilter.allowed?(:researcher, Loomkin.Tools.PeerMessage)
      assert ToolFilter.allowed?(:researcher, Loomkin.Tools.PeerCompleteTask)
      assert ToolFilter.allowed?(:researcher, Loomkin.Tools.ContextOffload)
    end

    test "coder can use write and exec tools" do
      assert ToolFilter.allowed?(:coder, Loomkin.Tools.FileWrite)
      assert ToolFilter.allowed?(:coder, Loomkin.Tools.FileEdit)
      assert ToolFilter.allowed?(:coder, Loomkin.Tools.Shell)
      assert ToolFilter.allowed?(:coder, Loomkin.Tools.Git)
    end

    test "coder cannot use sub_agent" do
      refute ToolFilter.allowed?(:coder, Loomkin.Tools.SubAgent)
    end

    test "coder cannot use lead tools" do
      refute ToolFilter.allowed?(:coder, Loomkin.Tools.TeamSpawn)
      refute ToolFilter.allowed?(:coder, Loomkin.Tools.TeamAssign)
    end

    test "reviewer cannot use write tools" do
      refute ToolFilter.allowed?(:reviewer, Loomkin.Tools.FileWrite)
      refute ToolFilter.allowed?(:reviewer, Loomkin.Tools.FileEdit)
    end

    test "reviewer can use shell for linters" do
      assert ToolFilter.allowed?(:reviewer, Loomkin.Tools.Shell)
    end

    test "weaver cannot use file tools" do
      refute ToolFilter.allowed?(:weaver, Loomkin.Tools.FileRead)
      refute ToolFilter.allowed?(:weaver, Loomkin.Tools.FileWrite)
      refute ToolFilter.allowed?(:weaver, Loomkin.Tools.Shell)
    end

    test "weaver can use coordination tools" do
      assert ToolFilter.allowed?(:weaver, Loomkin.Tools.TeamProgress)
      assert ToolFilter.allowed?(:weaver, Loomkin.Tools.PeerMessage)
      assert ToolFilter.allowed?(:weaver, Loomkin.Tools.DecisionLog)
    end

    test "unknown role returns true (permissive for custom roles)" do
      assert ToolFilter.allowed?(:custom_role_xyz, Loomkin.Tools.FileWrite)
    end

    test "unknown tool module returns false" do
      refute ToolFilter.allowed?(:coder, SomeNonexistentTool)
    end
  end

  describe "filter_tools/2" do
    test "filters out write tools for researcher" do
      input = [
        Loomkin.Tools.FileRead,
        Loomkin.Tools.FileWrite,
        Loomkin.Tools.FileEdit,
        Loomkin.Tools.ContentSearch,
        Loomkin.Tools.PeerMessage
      ]

      filtered = ToolFilter.filter_tools(:researcher, input)

      assert Loomkin.Tools.FileRead in filtered
      assert Loomkin.Tools.ContentSearch in filtered
      assert Loomkin.Tools.PeerMessage in filtered
      refute Loomkin.Tools.FileWrite in filtered
      refute Loomkin.Tools.FileEdit in filtered
    end

    test "filters out lead tools for coder" do
      input = [
        Loomkin.Tools.FileRead,
        Loomkin.Tools.FileWrite,
        Loomkin.Tools.TeamSpawn,
        Loomkin.Tools.SubAgent
      ]

      filtered = ToolFilter.filter_tools(:coder, input)

      assert Loomkin.Tools.FileRead in filtered
      assert Loomkin.Tools.FileWrite in filtered
      refute Loomkin.Tools.TeamSpawn in filtered
      refute Loomkin.Tools.SubAgent in filtered
    end

    test "returns tools unchanged for unknown role" do
      input = [Loomkin.Tools.FileRead, Loomkin.Tools.FileWrite]
      assert ToolFilter.filter_tools(:unknown_role, input) == input
    end
  end

  describe "category/1" do
    test "classifies read tools" do
      assert ToolFilter.category(Loomkin.Tools.FileRead) == :read
      assert ToolFilter.category(Loomkin.Tools.FileSearch) == :read
      assert ToolFilter.category(Loomkin.Tools.ContentSearch) == :read
      assert ToolFilter.category(Loomkin.Tools.DirectoryList) == :read
    end

    test "classifies write tools" do
      assert ToolFilter.category(Loomkin.Tools.FileWrite) == :write
      assert ToolFilter.category(Loomkin.Tools.FileEdit) == :write
    end

    test "classifies exec tools" do
      assert ToolFilter.category(Loomkin.Tools.Shell) == :exec
      assert ToolFilter.category(Loomkin.Tools.Git) == :exec
    end

    test "classifies investigation tools" do
      assert ToolFilter.category(Loomkin.Tools.SubAgent) == :investigation
      assert ToolFilter.category(Loomkin.Tools.LspDiagnostics) == :investigation
    end

    test "classifies peer tools" do
      assert ToolFilter.category(Loomkin.Tools.PeerMessage) == :peer
      assert ToolFilter.category(Loomkin.Tools.ContextRetrieve) == :peer
    end

    test "returns nil for unknown tool" do
      assert ToolFilter.category(SomeUnknownTool) == nil
    end
  end

  describe "categories_for_role/1" do
    test "researcher has read, decision, peer, and cross_team" do
      cats = ToolFilter.categories_for_role(:researcher)
      assert :read in cats
      assert :decision in cats
      assert :peer in cats
      assert :cross_team in cats

      refute :write in cats
      refute :exec in cats
      refute :lead in cats
      refute :investigation in cats
    end

    test "coder has read, write, exec, decision, peer, and cross_team" do
      cats = ToolFilter.categories_for_role(:coder)
      assert :read in cats
      assert :write in cats
      assert :exec in cats
      assert :decision in cats
      assert :peer in cats

      refute :lead in cats
      refute :investigation in cats
    end

    test "returns empty list for unknown role" do
      assert ToolFilter.categories_for_role(:nonexistent) == []
    end
  end

  describe "denial_reason/2" do
    test "provides informative denial message" do
      reason = ToolFilter.denial_reason(:researcher, Loomkin.Tools.FileWrite)
      assert reason =~ ":write"
      assert reason =~ ":researcher"
      assert reason =~ "Allowed categories"
    end
  end

  describe "consistency with Role module" do
    test "researcher role tools from Role.get match ToolFilter expectations" do
      {:ok, role} = Loomkin.Teams.Role.get(:researcher)

      # Every tool in the researcher role must be allowed by ToolFilter
      for tool <- role.tools do
        assert ToolFilter.allowed?(:researcher, tool),
               "Researcher role has tool #{inspect(tool)} which ToolFilter disallows"
      end

      # ToolFilter must NOT allow any write/exec/investigation tools for researcher
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.FileWrite)
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.FileEdit)
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.Shell)
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.Git)
      refute ToolFilter.allowed?(:researcher, Loomkin.Tools.SubAgent)
    end

    test "coder role tools from Role.get match ToolFilter expectations" do
      {:ok, role} = Loomkin.Teams.Role.get(:coder)

      for tool <- role.tools do
        assert ToolFilter.allowed?(:coder, tool),
               "Coder role has tool #{inspect(tool)} which ToolFilter disallows"
      end

      refute ToolFilter.allowed?(:coder, Loomkin.Tools.SubAgent)
      refute ToolFilter.allowed?(:coder, Loomkin.Tools.TeamSpawn)
    end

    test "reviewer role tools from Role.get match ToolFilter expectations" do
      {:ok, role} = Loomkin.Teams.Role.get(:reviewer)

      for tool <- role.tools do
        assert ToolFilter.allowed?(:reviewer, tool),
               "Reviewer role has tool #{inspect(tool)} which ToolFilter disallows"
      end

      refute ToolFilter.allowed?(:reviewer, Loomkin.Tools.FileWrite)
      refute ToolFilter.allowed?(:reviewer, Loomkin.Tools.FileEdit)
    end

    test "weaver role tools from Role.get match ToolFilter expectations" do
      {:ok, role} = Loomkin.Teams.Role.get(:weaver)

      for tool <- role.tools do
        assert ToolFilter.allowed?(:weaver, tool),
               "Weaver role has tool #{inspect(tool)} which ToolFilter disallows"
      end
    end
  end
end
