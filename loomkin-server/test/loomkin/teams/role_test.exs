defmodule Loomkin.Teams.RoleTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.Role

  describe "get/1" do
    test "returns :lead role with correct config" do
      assert {:ok, %Role{name: :lead}} = Role.get(:lead)
    end

    test "returns :researcher role with correct config" do
      assert {:ok, %Role{name: :researcher}} = Role.get(:researcher)
    end

    test "returns :coder role with correct config" do
      assert {:ok, %Role{name: :coder}} = Role.get(:coder)
    end

    test "returns :reviewer role with correct config" do
      assert {:ok, %Role{name: :reviewer}} = Role.get(:reviewer)
    end

    test "returns :tester role with correct config" do
      assert {:ok, %Role{name: :tester}} = Role.get(:tester)
    end

    test "returns :concierge role with correct config" do
      assert {:ok, %Role{name: :concierge}} = Role.get(:concierge)
    end

    test "returns error for unknown role" do
      assert {:error, :unknown_role} = Role.get(:nonexistent)
    end
  end

  describe "tool scoping" do
    test "lead has all tools" do
      {:ok, lead} = Role.get(:lead)
      assert Loomkin.Tools.FileRead in lead.tools
      assert Loomkin.Tools.FileWrite in lead.tools
      assert Loomkin.Tools.FileEdit in lead.tools
      assert Loomkin.Tools.Shell in lead.tools
      assert Loomkin.Tools.Git in lead.tools
      assert Loomkin.Tools.SubAgent in lead.tools
      assert Loomkin.Tools.DecisionLog in lead.tools
      assert Loomkin.Tools.DecisionQuery in lead.tools
      assert Loomkin.Tools.LspDiagnostics in lead.tools
    end

    test "researcher has read-only and decision tools only" do
      {:ok, researcher} = Role.get(:researcher)
      assert Loomkin.Tools.FileRead in researcher.tools
      assert Loomkin.Tools.FileSearch in researcher.tools
      assert Loomkin.Tools.ContentSearch in researcher.tools
      assert Loomkin.Tools.DirectoryList in researcher.tools
      assert Loomkin.Tools.DecisionLog in researcher.tools
      assert Loomkin.Tools.DecisionQuery in researcher.tools

      refute Loomkin.Tools.FileWrite in researcher.tools
      refute Loomkin.Tools.FileEdit in researcher.tools
      refute Loomkin.Tools.Shell in researcher.tools
      refute Loomkin.Tools.Git in researcher.tools
    end

    test "coder has read, write, exec, and decision_log tools" do
      {:ok, coder} = Role.get(:coder)
      assert Loomkin.Tools.FileRead in coder.tools
      assert Loomkin.Tools.FileWrite in coder.tools
      assert Loomkin.Tools.FileEdit in coder.tools
      assert Loomkin.Tools.Shell in coder.tools
      assert Loomkin.Tools.Git in coder.tools
      assert Loomkin.Tools.DecisionLog in coder.tools

      assert Loomkin.Tools.DecisionQuery in coder.tools
      refute Loomkin.Tools.SubAgent in coder.tools
    end

    test "reviewer has read-only, shell, and decision tools" do
      {:ok, reviewer} = Role.get(:reviewer)
      assert Loomkin.Tools.FileRead in reviewer.tools
      assert Loomkin.Tools.Shell in reviewer.tools
      assert Loomkin.Tools.DecisionLog in reviewer.tools
      assert Loomkin.Tools.DecisionQuery in reviewer.tools

      refute Loomkin.Tools.FileWrite in reviewer.tools
      refute Loomkin.Tools.FileEdit in reviewer.tools
      refute Loomkin.Tools.Git in reviewer.tools
    end

    test "tester has read-only, shell, and decision_log" do
      {:ok, tester} = Role.get(:tester)
      assert Loomkin.Tools.FileRead in tester.tools
      assert Loomkin.Tools.Shell in tester.tools
      assert Loomkin.Tools.DecisionLog in tester.tools

      assert Loomkin.Tools.DecisionQuery in tester.tools
      refute Loomkin.Tools.FileWrite in tester.tools
      refute Loomkin.Tools.FileEdit in tester.tools
      refute Loomkin.Tools.Git in tester.tools
    end
  end

  describe "model_for_tier/1" do
    test "returns default model for :default tier" do
      model = Role.model_for_tier(:default)
      assert is_binary(model)
      assert String.contains?(model, ":")
    end

    test "returns legacy model for legacy tier atoms (backward compat)" do
      assert "zai:glm-4.5" = Role.model_for_tier(:grunt)
      assert "zai:glm-5" = Role.model_for_tier(:standard)
      assert "zai:glm-5" = Role.model_for_tier(:expert)
      assert "zai:glm-5" = Role.model_for_tier(:architect)
    end

    test "falls back to default model for unknown tier" do
      model = Role.model_for_tier(:unknown)
      assert is_binary(model)
      assert String.contains?(model, ":")
    end
  end

  describe "built_in_roles/0" do
    test "lists all six built-in roles" do
      roles = Role.built_in_roles()
      assert length(roles) == 6
      assert :lead in roles
      assert :researcher in roles
      assert :coder in roles
      assert :reviewer in roles
      assert :tester in roles
      assert :concierge in roles
    end
  end

  describe "system prompts" do
    test "each role has a non-empty system prompt" do
      for role_name <- Role.built_in_roles() do
        {:ok, role} = Role.get(role_name)
        assert is_binary(role.system_prompt)
        assert String.length(role.system_prompt) > 50
      end
    end

    test "lead prompt mentions decomposition and coordination" do
      {:ok, lead} = Role.get(:lead)
      assert lead.system_prompt =~ "decomposition"
      assert lead.system_prompt =~ "coordination"
    end

    test "researcher prompt mentions explore and read-only" do
      {:ok, researcher} = Role.get(:researcher)
      assert researcher.system_prompt =~ "explore"
      assert researcher.system_prompt =~ "read-only"
    end

    test "coder prompt mentions implement and code style" do
      {:ok, coder} = Role.get(:coder)
      assert coder.system_prompt =~ "implement"
      assert coder.system_prompt =~ "code style"
    end

    test "reviewer prompt mentions review and security" do
      {:ok, reviewer} = Role.get(:reviewer)
      assert reviewer.system_prompt =~ "review"
      assert reviewer.system_prompt =~ "security"
    end

    test "tester prompt mentions tests and results" do
      {:ok, tester} = Role.get(:tester)
      assert tester.system_prompt =~ "test"
      assert tester.system_prompt =~ "results"
    end
  end

  describe "uniform model default" do
    test "all built-in roles use :default model_tier" do
      for role_name <- Role.built_in_roles() do
        {:ok, role} = Role.get(role_name)

        assert role.model_tier == :default,
               "Expected #{role_name} to have model_tier :default, got #{inspect(role.model_tier)}"
      end
    end
  end

  describe "research protocol content" do
    test "lead role system_prompt contains research protocol section" do
      {:ok, %Role{system_prompt: prompt}} = Role.get(:lead)
      assert prompt =~ "## Research Protocol"
      assert prompt =~ "spawn_type"
      assert prompt =~ "ask_user"
      assert prompt =~ "team_dissolve"
    end

    test "researcher role system_prompt contains structured findings format" do
      {:ok, %Role{system_prompt: prompt}} = Role.get(:researcher)
      assert prompt =~ "## Research Findings"
      assert prompt =~ "## Recommendation"
      assert prompt =~ "peer_message"
    end
  end

  describe "from_config/2" do
    test "creates a custom role from a config map" do
      config = %{
        model_tier: :expert,
        system_prompt: "You are a custom agent.",
        budget_limit: 5.0
      }

      role = Role.from_config(:custom_role, config)

      assert role.name == :custom_role
      assert role.model_tier == :expert
      assert role.system_prompt == "You are a custom agent."
      assert role.budget_limit == 5.0
    end

    test "overrides a built-in role with config values" do
      config = %{
        budget_limit: 10.0
      }

      role = Role.from_config(:coder, config)

      assert role.name == :coder
      assert role.budget_limit == 10.0
      # Preserves defaults not overridden
      assert role.model_tier == :default
      assert role.system_prompt =~ "implement"
    end

    test "accepts string keys in config map" do
      config = %{
        "model_tier" => :grunt,
        "system_prompt" => "String key prompt."
      }

      role = Role.from_config(:custom, config)

      assert role.model_tier == :grunt
      assert role.system_prompt == "String key prompt."
    end

    test "resolves tool names from strings" do
      config = %{
        tools: ["file_read", "shell"]
      }

      role = Role.from_config(:limited, config)

      assert role.tools == [Loomkin.Tools.FileRead, Loomkin.Tools.Shell]
    end

    test "preserves tool modules passed directly" do
      config = %{
        tools: [Loomkin.Tools.FileRead, Loomkin.Tools.Git]
      }

      role = Role.from_config(:direct, config)

      assert role.tools == [Loomkin.Tools.FileRead, Loomkin.Tools.Git]
    end
  end

  describe "communication graph" do
    test "append_context_awareness includes Communication Priority section for specialists" do
      for role_name <- [:researcher, :coder, :reviewer, :tester, :lead, :concierge] do
        {:ok, role} = Role.get(role_name)

        assert role.system_prompt =~ "### Communication Priority",
               "Expected #{role_name} prompt to include Communication Priority section"

        assert role.system_prompt =~ "Keep close tabs with",
               "Expected #{role_name} prompt to include 'Keep close tabs with'"
      end
    end

    test "researcher prompt mentions coder and lead as primary contacts" do
      {:ok, researcher} = Role.get(:researcher)
      assert researcher.system_prompt =~ "**Keep close tabs with:** coder, lead"
    end

    test "coder prompt mentions researcher and reviewer as primary contacts" do
      {:ok, coder} = Role.get(:coder)
      assert coder.system_prompt =~ "**Keep close tabs with:** researcher, reviewer"
    end

    test "communication graph entries exist for all built-in roles" do
      for role_name <- Role.built_in_roles() do
        {:ok, role} = Role.get(role_name)

        assert role.system_prompt =~ "### Communication Priority",
               "Expected #{role_name} to have a communication graph entry"
      end
    end

    test "duplicate prevention included for all roles" do
      for role_name <- Role.built_in_roles() do
        {:ok, role} = Role.get(role_name)

        assert role.system_prompt =~ "## Duplicate Work Prevention",
               "Expected #{role_name} prompt to include Duplicate Work Prevention"
      end
    end
  end
end
