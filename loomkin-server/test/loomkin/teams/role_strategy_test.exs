defmodule Loomkin.Teams.RoleStrategyTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.Role

  describe "reasoning_strategy field" do
    test "built-in roles have reasoning_strategy" do
      for role_name <- Role.built_in_roles() do
        {:ok, role} = Role.get(role_name)

        assert role.reasoning_strategy in [:react, :cot, :cod, :tot, :adaptive],
               "Role #{role_name} has invalid reasoning_strategy: #{inspect(role.reasoning_strategy)}"
      end
    end

    test "concierge uses :react strategy" do
      {:ok, role} = Role.get(:concierge)
      assert role.reasoning_strategy == :react
    end

    test "coder uses :react strategy" do
      {:ok, role} = Role.get(:coder)
      assert role.reasoning_strategy == :react
    end

    test "lead uses :react strategy" do
      {:ok, role} = Role.get(:lead)
      assert role.reasoning_strategy == :react
    end

    test "researcher uses :react strategy" do
      {:ok, role} = Role.get(:researcher)
      assert role.reasoning_strategy == :react
    end

    test "default reasoning_strategy is :react" do
      # A brand new struct should default to :react
      role = %Role{}
      assert role.reasoning_strategy == :react
    end

    test "from_config preserves reasoning_strategy override" do
      role = Role.from_config(:coder, %{reasoning_strategy: :cot})
      assert role.reasoning_strategy == :cot
    end

    test "from_config uses built-in default when not overridden" do
      role = Role.from_config(:researcher, %{})
      assert role.reasoning_strategy == :react
    end

    test "from_config for unknown role defaults to :react" do
      role = Role.from_config(:custom_role, %{system_prompt: "Custom", tools: []})
      assert role.reasoning_strategy == :react
    end
  end
end
