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
      defaults = Loomkin.Config.defaults()
      assert model.default == defaults.model.default
      assert is_nil(model.editor)
    end

    test "get/2 returns nested values" do
      defaults = Loomkin.Config.defaults()
      assert Loomkin.Config.get(:model, :default) == defaults.model.default
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
      default = "zai:glm-5"
      editor = "zai:glm-4.5"
      """

      File.write!(Path.join(@test_dir, ".loomkin.toml"), toml_content)

      Loomkin.Config.load(@test_dir)

      assert Loomkin.Config.get(:model, :default) == "zai:glm-5"
      assert Loomkin.Config.get(:model, :editor) == "zai:glm-4.5"
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

  describe "consensus_policy/0" do
    test "returns default policy when no config is set" do
      policy = Loomkin.Config.consensus_policy()
      assert %Loomkin.Teams.ConsensusPolicy{} = policy
      assert policy.quorum == :majority
      assert policy.max_rounds == 3
      assert policy.scope == "general"
      assert policy.on_deadlock == :escalate_to_user
    end

    test "loads policy from [teams.consensus] in .loomkin.toml" do
      File.mkdir_p!(@test_dir)

      toml_content = """
      [teams.consensus]
      quorum = "supermajority"
      max_rounds = 5
      scope = "architecture"
      on_deadlock = "leader_decides"
      """

      File.write!(Path.join(@test_dir, ".loomkin.toml"), toml_content)
      Loomkin.Config.load(@test_dir)

      policy = Loomkin.Config.consensus_policy()
      assert policy.quorum == :supermajority
      assert policy.max_rounds == 5
      assert policy.scope == "architecture"
      assert policy.on_deadlock == :leader_decides
    after
      File.rm_rf!(@test_dir)
    end

    test "falls back to defaults when config has invalid values" do
      File.mkdir_p!(@test_dir)

      toml_content = """
      [teams.consensus]
      quorum = "invalid_mode"
      max_rounds = -1
      """

      File.write!(Path.join(@test_dir, ".loomkin.toml"), toml_content)
      Loomkin.Config.load(@test_dir)

      # Should fall back to default since validation fails
      policy = Loomkin.Config.consensus_policy()
      assert policy == Loomkin.Teams.ConsensusPolicy.default()
    after
      File.rm_rf!(@test_dir)
    end
  end

  describe "put/2" do
    test "overrides a config value for the session" do
      Loomkin.Config.put(:model, %{default: "custom:model", editor: "custom:editor"})

      assert Loomkin.Config.get(:model, :default) == "custom:model"
      assert Loomkin.Config.get(:model, :editor) == "custom:editor"
    after
      Loomkin.Config.load(@test_dir)
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

  describe "put_nested/2" do
    test "updates a nested key path" do
      Loomkin.Config.put_nested([:teams, :consensus, :quorum], "unanimous")

      assert Loomkin.Config.get(:teams) |> get_in([:consensus, :quorum]) == "unanimous"
    after
      Loomkin.Config.load(@test_dir)
    end

    test "creates intermediate maps if they don't exist" do
      Loomkin.Config.put_nested([:agents, :max_iterations], 50)

      assert Loomkin.Config.get(:agents) |> Map.get(:max_iterations) == 50
    after
      Loomkin.Config.load(@test_dir)
    end

    test "preserves sibling keys when updating nested value" do
      original_mode = Loomkin.Config.get(:teams, :orchestrator_mode)
      Loomkin.Config.put_nested([:teams, :consensus, :quorum], "unanimous")

      assert Loomkin.Config.get(:teams, :orchestrator_mode) == original_mode
    after
      Loomkin.Config.load(@test_dir)
    end
  end

  describe "save_to_file/1" do
    test "writes config to .loomkin.toml" do
      File.mkdir_p!(@test_dir)

      Loomkin.Config.save_to_file(@test_dir)

      toml_path = Path.join(@test_dir, ".loomkin.toml")
      assert File.exists?(toml_path)

      content = File.read!(toml_path)
      assert content =~ "[model]"
      assert content =~ "[permissions]"
    after
      File.rm_rf!(@test_dir)
    end

    test "saved file can be parsed back by Toml" do
      File.mkdir_p!(@test_dir)

      Loomkin.Config.save_to_file(@test_dir)

      toml_path = Path.join(@test_dir, ".loomkin.toml")
      assert {:ok, parsed} = Toml.decode_file(toml_path)
      assert is_map(parsed)
    after
      File.rm_rf!(@test_dir)
    end
  end

  describe "reset_key/1" do
    test "restores a key to its default value" do
      Loomkin.Config.put_nested([:context, :max_repo_map_tokens], 8192)
      assert Loomkin.Config.get(:context, :max_repo_map_tokens) == 8192

      Loomkin.Config.reset_key([:context, :max_repo_map_tokens])
      assert Loomkin.Config.get(:context, :max_repo_map_tokens) == 2048
    after
      Loomkin.Config.load(@test_dir)
    end
  end
end
