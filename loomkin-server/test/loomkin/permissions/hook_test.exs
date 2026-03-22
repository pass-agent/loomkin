defmodule Loomkin.Permissions.HookRunnerTest do
  use ExUnit.Case, async: true

  alias Loomkin.Permissions.HookRunner
  alias Loomkin.Permissions.Hooks.MockAllowHook
  alias Loomkin.Permissions.Hooks.MockAskHook
  alias Loomkin.Permissions.Hooks.MockDenyHook
  alias Loomkin.Permissions.Hooks.MockPreOnlyHook
  alias Loomkin.Permissions.Hooks.MockWarnHook

  # -- run_pre_hooks/3 --------------------------------------------------------

  describe "run_pre_hooks/3" do
    test "returns :allow with empty hooks list" do
      assert :allow == HookRunner.run_pre_hooks([], "file_write", %{})
    end

    test "returns :allow when all hooks allow" do
      hooks = [MockAllowHook, MockAllowHook]
      assert :allow == HookRunner.run_pre_hooks(hooks, "file_write", %{})
    end

    test "short-circuits on :deny" do
      hooks = [MockAllowHook, MockDenyHook, MockAllowHook]
      assert :deny == HookRunner.run_pre_hooks(hooks, "file_write", %{})
    end

    test "short-circuits on {:ask, reason}" do
      hooks = [MockAllowHook, MockAskHook, MockDenyHook]
      assert {:ask, "needs confirmation"} == HookRunner.run_pre_hooks(hooks, "file_edit", %{})
    end

    test "skips hooks for :read category tools" do
      hooks = [MockDenyHook]
      assert :allow == HookRunner.run_pre_hooks(hooks, "file_read", %{})
      assert :allow == HookRunner.run_pre_hooks(hooks, "content_search", %{})
      assert :allow == HookRunner.run_pre_hooks(hooks, "directory_list", %{})
      assert :allow == HookRunner.run_pre_hooks(hooks, "file_search", %{})
    end

    test "skips hooks for :coordination category tools" do
      hooks = [MockDenyHook]
      assert :allow == HookRunner.run_pre_hooks(hooks, "peer_message", %{})
      assert :allow == HookRunner.run_pre_hooks(hooks, "team_spawn", %{})
    end

    test "runs hooks for :write category tools" do
      hooks = [MockDenyHook]
      assert :deny == HookRunner.run_pre_hooks(hooks, "file_write", %{})
      assert :deny == HookRunner.run_pre_hooks(hooks, "file_edit", %{})
    end

    test "runs hooks for :execute category tools" do
      hooks = [MockDenyHook]
      assert :deny == HookRunner.run_pre_hooks(hooks, "shell", %{})
      assert :deny == HookRunner.run_pre_hooks(hooks, "git", %{})
    end

    test "skips hooks that do not export pre_tool/2" do
      # MockPreOnlyHook exports pre_tool, MockWarnHook does not
      hooks = [MockWarnHook, MockAllowHook]
      assert :allow == HookRunner.run_pre_hooks(hooks, "file_write", %{})
    end
  end

  # -- run_post_hooks/4 -------------------------------------------------------

  describe "run_post_hooks/4" do
    test "returns :ok with empty hooks list" do
      assert :ok == HookRunner.run_post_hooks([], "file_write", %{}, "success")
    end

    test "returns :ok when all hooks return :ok" do
      hooks = [MockAllowHook, MockAllowHook]
      assert :ok == HookRunner.run_post_hooks(hooks, "file_write", %{}, "success")
    end

    test "short-circuits on {:rollback, reason}" do
      hooks = [MockAllowHook, MockDenyHook, MockAllowHook]
      assert {:rollback, "denied"} == HookRunner.run_post_hooks(hooks, "file_write", %{}, "ok")
    end

    test "collects warnings but returns :ok if no rollback" do
      hooks = [MockWarnHook, MockAllowHook]
      assert :ok == HookRunner.run_post_hooks(hooks, "file_write", %{}, "ok")
    end

    test "warning followed by rollback returns the rollback" do
      hooks = [MockWarnHook, MockDenyHook]

      assert {:rollback, "denied"} ==
               HookRunner.run_post_hooks(hooks, "file_edit", %{}, "result")
    end

    test "skips hooks for :read category tools" do
      hooks = [MockDenyHook]
      assert :ok == HookRunner.run_post_hooks(hooks, "file_read", %{}, "result")
    end

    test "skips hooks for :coordination category tools" do
      hooks = [MockDenyHook]
      assert :ok == HookRunner.run_post_hooks(hooks, "team_spawn", %{}, "result")
    end

    test "skips hooks that do not export post_tool/3" do
      hooks = [MockPreOnlyHook, MockAllowHook]
      assert :ok == HookRunner.run_post_hooks(hooks, "file_write", %{}, "result")
    end
  end

  # -- load_hooks/1 -----------------------------------------------------------

  describe "load_hooks/1" do
    test "returns configured modules for :pre_tool" do
      config = %{pre_tool: [MockAllowHook, MockDenyHook], post_tool: [MockWarnHook]}
      Application.put_env(:loomkin, :permission_hooks, config)

      assert [MockAllowHook, MockDenyHook] == HookRunner.load_hooks(:pre_tool)
    after
      Application.delete_env(:loomkin, :permission_hooks)
    end

    test "returns configured modules for :post_tool" do
      config = %{pre_tool: [MockAllowHook], post_tool: [MockWarnHook, MockDenyHook]}
      Application.put_env(:loomkin, :permission_hooks, config)

      assert [MockWarnHook, MockDenyHook] == HookRunner.load_hooks(:post_tool)
    after
      Application.delete_env(:loomkin, :permission_hooks)
    end

    test "returns empty list when no hooks configured" do
      Application.delete_env(:loomkin, :permission_hooks)
      assert [] == HookRunner.load_hooks(:pre_tool)
      assert [] == HookRunner.load_hooks(:post_tool)
    end

    test "returns empty list when phase is not in config map" do
      Application.put_env(:loomkin, :permission_hooks, %{pre_tool: [MockAllowHook]})
      assert [] == HookRunner.load_hooks(:post_tool)
    after
      Application.delete_env(:loomkin, :permission_hooks)
    end
  end
end
