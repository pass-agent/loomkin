defmodule Loomkin.Settings.RegistryTest do
  use ExUnit.Case, async: true

  alias Loomkin.Settings.Registry
  alias Loomkin.Settings.Setting

  describe "all/0" do
    test "returns a list of Setting structs" do
      settings = Registry.all()
      assert is_list(settings)
      assert length(settings) > 0
      assert Enum.all?(settings, &match?(%Setting{}, &1))
    end

    test "every setting has required fields" do
      for setting <- Registry.all() do
        assert is_list(setting.key) and length(setting.key) >= 2,
               "#{inspect(setting.key)} must be a list with at least 2 elements"

        assert is_binary(setting.label), "#{inspect(setting.key)} missing label"
        assert is_binary(setting.description), "#{inspect(setting.key)} missing description"
        assert is_binary(setting.why_change), "#{inspect(setting.key)} missing why_change"
        assert setting.type in [:number, :toggle, :select, :duration, :currency, :tag_list]
        assert setting.default != nil, "#{inspect(setting.key)} missing default"
        assert is_binary(setting.tab), "#{inspect(setting.key)} missing tab"
        assert is_binary(setting.section), "#{inspect(setting.key)} missing section"
      end
    end

    test "no duplicate keys" do
      keys = Enum.map(Registry.all(), fn s -> Registry.key_string(s.key) end)
      assert length(keys) == length(Enum.uniq(keys))
    end

    test "select settings have options" do
      for setting <- Registry.all(), setting.type == :select do
        assert is_list(setting.options) and length(setting.options) > 0,
               "#{inspect(setting.key)} select missing options"

        assert to_string(setting.default) in setting.options,
               "#{inspect(setting.key)} default not in options"
      end
    end

    test "number/duration/currency settings with range have valid defaults" do
      for setting <- Registry.all(), setting.range != nil do
        {min, max} = setting.range

        assert setting.default >= min and setting.default <= max,
               "#{inspect(setting.key)} default #{setting.default} outside range #{min}..#{max}"
      end
    end
  end

  describe "tabs/0" do
    test "returns ordered list of tab names" do
      tabs = Registry.tabs()
      assert is_list(tabs)
      assert "Agents" in tabs
      assert "Budgets" in tabs
      assert "Healing" in tabs
      assert "Intelligence" in tabs
      assert "Safety" in tabs
    end
  end

  describe "by_tab/1" do
    test "returns settings grouped by section" do
      sections = Registry.by_tab("Agents")
      assert is_map(sections)
      assert Map.has_key?(sections, "Team Structure")
      assert Map.has_key?(sections, "Execution Limits")
    end

    test "returns empty map for unknown tab" do
      assert Registry.by_tab("Nonexistent") == %{}
    end
  end

  describe "by_key/1" do
    test "looks up by dot-path string" do
      setting = Registry.by_key("agents.max_iterations")
      assert %Setting{} = setting
      assert setting.label == "Max loop iterations"
      assert setting.default == 25
    end

    test "returns nil for unknown key" do
      assert Registry.by_key("unknown.key") == nil
    end
  end

  describe "validate/2" do
    test "validates number within range" do
      setting = Registry.by_key("agents.max_iterations")
      assert :ok = Registry.validate(setting, 50)
      assert {:error, _} = Registry.validate(setting, 0)
      assert {:error, _} = Registry.validate(setting, 200)
      assert {:error, _} = Registry.validate(setting, "not a number")
    end

    test "validates toggle" do
      setting = Registry.by_key("teams.orchestrator_mode")
      assert :ok = Registry.validate(setting, true)
      assert :ok = Registry.validate(setting, false)
      assert {:error, _} = Registry.validate(setting, "yes")
    end

    test "validates select" do
      setting = Registry.by_key("teams.consensus.quorum")
      assert :ok = Registry.validate(setting, "majority")
      assert :ok = Registry.validate(setting, "unanimous")
      assert {:error, _} = Registry.validate(setting, "invalid")
    end

    test "validates currency" do
      setting = Registry.by_key("teams.budget.max_per_team_usd")
      assert :ok = Registry.validate(setting, 5.00)
      assert {:error, _} = Registry.validate(setting, 0.01)
      assert {:error, _} = Registry.validate(setting, "five")
    end

    test "validates tag_list" do
      setting = Registry.by_key("permissions.auto_approve")
      assert :ok = Registry.validate(setting, ["a", "b"])
      assert {:error, _} = Registry.validate(setting, "not a list")
      assert {:error, _} = Registry.validate(setting, [1, 2])
    end

    test "validates duration" do
      setting = Registry.by_key("agents.shell_timeout_ms")
      assert :ok = Registry.validate(setting, 30_000)
      assert {:error, _} = Registry.validate(setting, 500)
      assert {:error, _} = Registry.validate(setting, "fast")
    end
  end

  describe "current_values/0" do
    test "returns flat map keyed by dot-path strings" do
      values = Registry.current_values()
      assert is_map(values)
      assert Map.has_key?(values, "agents.max_iterations")
      assert Map.has_key?(values, "teams.orchestrator_mode")
    end
  end

  describe "key_string/1" do
    test "converts atom list to dot-separated string" do
      assert Registry.key_string([:teams, :consensus, :quorum]) == "teams.consensus.quorum"
      assert Registry.key_string([:agents, :max_iterations]) == "agents.max_iterations"
    end
  end
end
