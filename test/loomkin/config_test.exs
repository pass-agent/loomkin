defmodule Loomkin.ConfigTest do
  use ExUnit.Case, async: false

  @test_dir System.tmp_dir!()
            |> Path.join("loom_config_test_#{System.unique_integer([:positive])}")

  setup do
    # Config GenServer is already running via the application
    # Reset to defaults before each test
    Loomkin.Config.load(@test_dir)
    :ok
  end

  describe "defaults" do
    test "get/1 returns default model config" do
      model = Loomkin.Config.get(:model)
      assert model.default == "anthropic:claude-sonnet-4-6"
      assert is_nil(model.editor)
    end

    test "get/2 returns nested values" do
      assert Loomkin.Config.get(:model, :default) == "anthropic:claude-sonnet-4-6"
      assert is_nil(Loomkin.Config.get(:model, :editor))
    end

    test "get/1 returns default permissions" do
      perms = Loomkin.Config.get(:permissions)
      assert "file_read" in perms.auto_approve
      assert "content_search" in perms.auto_approve
    end

    test "get/1 returns default context config" do
      ctx = Loomkin.Config.get(:context)
      assert ctx.max_repo_map_tokens == 2048
      assert ctx.reserved_output_tokens == 4096
    end

    test "get/1 returns default decisions config" do
      decisions = Loomkin.Config.get(:decisions)
      assert decisions.enabled == true
      assert decisions.enforce_pre_edit == false
    end

    test "get/1 returns nil for unknown keys" do
      assert Loomkin.Config.get(:nonexistent) == nil
    end

    test "get/2 returns nil for unknown subkeys" do
      assert Loomkin.Config.get(:model, :nonexistent) == nil
    end
  end

  describe "load/1" do
    test "loads from .loomkin.toml and merges with defaults" do
      File.mkdir_p!(@test_dir)

      toml_content = """
      [model]
      default = "openai:gpt-4o"

      [permissions]
      auto_approve = ["file_read", "shell"]
      """

      File.write!(Path.join(@test_dir, ".loomkin.toml"), toml_content)

      Loomkin.Config.load(@test_dir)

      # Overridden values
      assert Loomkin.Config.get(:model, :default) == "openai:gpt-4o"
      assert "shell" in Loomkin.Config.get(:permissions, :auto_approve)

      # Preserved defaults (deep merge keeps non-overridden keys)
      assert is_nil(Loomkin.Config.get(:model, :editor))
      assert Loomkin.Config.get(:context, :max_repo_map_tokens) == 2048
    after
      File.rm_rf!(@test_dir)
    end

    test "loads editor model from .loomkin.toml when explicitly set" do
      File.mkdir_p!(@test_dir)

      toml_content = """
      [model]
      default = "anthropic:claude-sonnet-4-6"
      editor = "anthropic:claude-haiku-4-5"
      """

      File.write!(Path.join(@test_dir, ".loomkin.toml"), toml_content)

      Loomkin.Config.load(@test_dir)

      assert Loomkin.Config.get(:model, :default) == "anthropic:claude-sonnet-4-6"
      assert Loomkin.Config.get(:model, :editor) == "anthropic:claude-haiku-4-5"
    after
      File.rm_rf!(@test_dir)
    end

    test "unknown TOML sections do not prevent known keys from atomizing" do
      File.mkdir_p!(@test_dir)

      toml_content = """
      [model]
      default = "openai:gpt-4o"

      [my_custom_thing]
      foo = "bar"
      """

      File.write!(Path.join(@test_dir, ".loomkin.toml"), toml_content)

      Loomkin.Config.load(@test_dir)

      # Known keys should still be atomized and accessible
      assert Loomkin.Config.get(:model, :default) == "openai:gpt-4o"
    after
      File.rm_rf!(@test_dir)
    end

    test "uses defaults when .loomkin.toml doesn't exist" do
      Loomkin.Config.load("/tmp/nonexistent_loom_path")

      defaults = Loomkin.Config.defaults()
      assert Loomkin.Config.get(:model) == defaults.model
      assert Loomkin.Config.get(:permissions) == defaults.permissions
    end
  end

  describe "put/2" do
    test "overrides a config value for the session" do
      Loomkin.Config.put(:model, %{default: "custom:model", editor: "custom:editor"})

      assert Loomkin.Config.get(:model, :default) == "custom:model"
      assert Loomkin.Config.get(:model, :editor) == "custom:editor"
    end
  end

  describe "all/0" do
    test "returns the full config map" do
      config = Loomkin.Config.all()
      assert is_map(config)
      assert Map.has_key?(config, :model)
      assert Map.has_key?(config, :permissions)
      assert Map.has_key?(config, :context)
      assert Map.has_key?(config, :decisions)
    end
  end
end
