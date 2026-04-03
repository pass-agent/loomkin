defmodule Loomkin.Teams.RoleHealingPolicyTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.Role

  describe "healing_policy struct field" do
    test "all built-in roles include a healing_policy map" do
      for role_name <- Role.built_in_roles() do
        {:ok, role} = Role.get(role_name)
        assert is_map(role.healing_policy), "#{role_name} should have a healing_policy map"

        assert Map.has_key?(role.healing_policy, :enabled),
               "#{role_name} healing_policy missing :enabled"

        assert Map.has_key?(role.healing_policy, :categories),
               "#{role_name} healing_policy missing :categories"

        assert Map.has_key?(role.healing_policy, :min_severity),
               "#{role_name} healing_policy missing :min_severity"

        assert Map.has_key?(role.healing_policy, :failure_threshold),
               "#{role_name} healing_policy missing :failure_threshold"

        assert Map.has_key?(role.healing_policy, :budget_usd),
               "#{role_name} healing_policy missing :budget_usd"

        assert Map.has_key?(role.healing_policy, :max_attempts),
               "#{role_name} healing_policy missing :max_attempts"

        assert Map.has_key?(role.healing_policy, :timeout_ms),
               "#{role_name} healing_policy missing :timeout_ms"
      end
    end
  end

  describe "default policies by role" do
    test "coder: enabled, all healable categories, threshold 1" do
      {:ok, role} = Role.get(:coder)
      policy = role.healing_policy

      assert policy.enabled == true
      assert :compile_error in policy.categories
      assert :lint_error in policy.categories
      assert :command_failure in policy.categories
      assert :test_failure in policy.categories
      assert :tool_error in policy.categories
      assert policy.failure_threshold == 1
      assert policy.budget_usd == 0.50
      assert policy.max_attempts == 2
      assert policy.timeout_ms == :timer.minutes(5)
    end

    test "tester: enabled, compile/command/test, threshold 1" do
      {:ok, role} = Role.get(:tester)
      policy = role.healing_policy

      assert policy.enabled == true
      assert :compile_error in policy.categories
      assert :command_failure in policy.categories
      assert :test_failure in policy.categories
      refute :lint_error in policy.categories
      refute :tool_error in policy.categories
      assert policy.failure_threshold == 1
    end

    test "researcher: enabled, command/tool, threshold 2" do
      {:ok, role} = Role.get(:researcher)
      policy = role.healing_policy

      assert policy.enabled == true
      assert :command_failure in policy.categories
      assert :tool_error in policy.categories
      refute :compile_error in policy.categories
      refute :lint_error in policy.categories
      refute :test_failure in policy.categories
      assert policy.failure_threshold == 2
    end

    test "reviewer: disabled" do
      {:ok, role} = Role.get(:reviewer)
      policy = role.healing_policy

      assert policy.enabled == false
      assert policy.categories == []
    end

    test "lead: disabled" do
      {:ok, role} = Role.get(:lead)
      policy = role.healing_policy

      assert policy.enabled == false
      assert policy.categories == []
    end

    test "concierge: disabled" do
      {:ok, role} = Role.get(:concierge)
      policy = role.healing_policy

      assert policy.enabled == false
      assert policy.categories == []
    end
  end

  describe "healing_policy/1" do
    test "returns correct policy for known built-in roles" do
      policy = Role.healing_policy(:coder)
      assert policy.enabled == true
      assert policy.failure_threshold == 1
    end

    test "returns default custom policy for unknown role names" do
      policy = Role.healing_policy(:some_unknown_role)
      assert policy.enabled == true
      assert :compile_error in policy.categories
      assert :lint_error in policy.categories
      assert :command_failure in policy.categories
      refute :test_failure in policy.categories
      refute :tool_error in policy.categories
      assert policy.failure_threshold == 2
    end
  end

  describe "default_custom_healing_policy/0" do
    test "returns conservative defaults for custom roles" do
      policy = Role.default_custom_healing_policy()

      assert policy.enabled == true
      assert :compile_error in policy.categories
      assert :lint_error in policy.categories
      assert :command_failure in policy.categories
      refute :test_failure in policy.categories
      refute :tool_error in policy.categories
      assert policy.failure_threshold == 2
      assert policy.min_severity == :medium
      assert policy.budget_usd == 0.50
      assert policy.max_attempts == 2
      assert policy.timeout_ms == :timer.minutes(5)
    end
  end

  describe "healable_categories/0" do
    test "returns all healable error categories" do
      cats = Role.healable_categories()
      assert :compile_error in cats
      assert :lint_error in cats
      assert :command_failure in cats
      assert :test_failure in cats
      assert :tool_error in cats
      assert length(cats) == 5
    end
  end

  describe "valid_severities/0" do
    test "returns severity levels" do
      sevs = Role.valid_severities()
      assert sevs == [:low, :medium, :high, :critical]
    end
  end

  describe "from_config/2 with healing_policy" do
    test "custom role gets default custom healing policy" do
      config = %{system_prompt: "Custom agent."}
      role = Role.from_config(:my_custom, config)

      assert role.healing_policy.enabled == true
      assert role.healing_policy.failure_threshold == 2
      assert :compile_error in role.healing_policy.categories
    end

    test "built-in role override preserves base healing policy" do
      config = %{budget_limit: 10.0}
      role = Role.from_config(:coder, config)

      assert role.healing_policy.enabled == true
      assert role.healing_policy.failure_threshold == 1
      assert :tool_error in role.healing_policy.categories
    end

    test "healing_policy can be partially overridden via config" do
      config = %{
        healing_policy: %{enabled: false, failure_threshold: 5}
      }

      role = Role.from_config(:coder, config)

      assert role.healing_policy.enabled == false
      assert role.healing_policy.failure_threshold == 5
      # Non-overridden fields retain their defaults
      assert :compile_error in role.healing_policy.categories
      assert role.healing_policy.budget_usd == 0.50
    end

    test "healing_policy override with string keys works" do
      config = %{
        "healing_policy" => %{"enabled" => false}
      }

      role = Role.from_config(:coder, config)
      assert role.healing_policy.enabled == false
      # Other fields from coder default
      assert role.healing_policy.failure_threshold == 1
    end

    test "invalid categories are filtered out during merge" do
      config = %{
        healing_policy: %{categories: [:compile_error, :bogus_category, :lint_error]}
      }

      role = Role.from_config(:researcher, config)

      assert :compile_error in role.healing_policy.categories
      assert :lint_error in role.healing_policy.categories
      refute :bogus_category in role.healing_policy.categories
    end

    test "invalid severity falls back to :medium" do
      config = %{
        healing_policy: %{min_severity: :super_critical}
      }

      role = Role.from_config(:coder, config)
      assert role.healing_policy.min_severity == :medium
    end
  end

  describe "disabling healing per-role" do
    test "disabled roles have empty categories and zero budget" do
      for role_name <- [:reviewer, :lead, :concierge] do
        {:ok, role} = Role.get(role_name)
        policy = role.healing_policy

        assert policy.enabled == false,
               "#{role_name} should have healing disabled"

        assert policy.categories == [],
               "#{role_name} should have empty categories"

        assert policy.budget_usd == 0.0,
               "#{role_name} should have zero budget"
      end
    end

    test "enabled roles have non-empty categories and positive budget" do
      for role_name <- [:coder, :tester, :researcher] do
        {:ok, role} = Role.get(role_name)
        policy = role.healing_policy

        assert policy.enabled == true,
               "#{role_name} should have healing enabled"

        assert length(policy.categories) > 0,
               "#{role_name} should have at least one category"

        assert policy.budget_usd > 0.0,
               "#{role_name} should have positive budget"
      end
    end
  end
end
