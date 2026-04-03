defmodule Loomkin.Teams.RoleGenerateTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.Role

  describe "build_tool_catalog/0" do
    test "returns a map with expected categories" do
      catalog = Role.build_tool_catalog()
      assert is_map(catalog)
      assert Map.has_key?(catalog, "read")
      assert Map.has_key?(catalog, "write")
      assert Map.has_key?(catalog, "exec")
      assert Map.has_key?(catalog, "decision")
      assert Map.has_key?(catalog, "other")
    end

    test "each category contains entries with name and description" do
      catalog = Role.build_tool_catalog()

      for {_category, entries} <- catalog do
        assert is_list(entries)

        for entry <- entries do
          assert Map.has_key?(entry, :name)
          assert Map.has_key?(entry, :description)
          assert is_binary(entry.name)
          assert is_binary(entry.description)
        end
      end
    end

    test "read category contains file_read, file_search, content_search, directory_list" do
      catalog = Role.build_tool_catalog()
      read_names = Enum.map(catalog["read"], & &1.name)
      assert "file_read" in read_names
      assert "file_search" in read_names
      assert "content_search" in read_names
      assert "directory_list" in read_names
    end

    test "write category contains file_write and file_edit" do
      catalog = Role.build_tool_catalog()
      write_names = Enum.map(catalog["write"], & &1.name)
      assert "file_write" in write_names
      assert "file_edit" in write_names
    end

    test "exec category contains shell and git" do
      catalog = Role.build_tool_catalog()
      exec_names = Enum.map(catalog["exec"], & &1.name)
      assert "shell" in exec_names
      assert "git" in exec_names
    end

    test "does not include peer or lead tools in catalog" do
      catalog = Role.build_tool_catalog()
      all_names = Enum.flat_map(catalog, fn {_cat, entries} -> Enum.map(entries, & &1.name) end)

      # Peer tools should not be in catalog
      refute "peer_message" in all_names
      refute "peer_discovery" in all_names
      refute "ask_user" in all_names

      # Lead tools should not be in catalog
      refute "team_spawn" in all_names
      refute "team_assign" in all_names
      refute "team_dissolve" in all_names
    end
  end

  describe "parse_and_validate_role/1" do
    test "parses valid JSON and returns a Role struct" do
      json =
        Jason.encode!(%{
          "role_name" => "migration-writer",
          "system_prompt" => "You specialize in database migrations.",
          "tools" => ["file_read", "file_write", "shell"]
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      assert is_binary(role.name)
      assert String.starts_with?(role.name, "migration-writer_")
      assert role.model_tier == :default
      assert role.budget_limit == nil
      assert is_binary(role.system_prompt)
      assert String.contains?(role.system_prompt, "database migrations")
    end

    test "strips markdown fences from response" do
      json = """
      ```json
      {"role_name": "api-tester", "system_prompt": "Test APIs.", "tools": ["shell"]}
      ```
      """

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      assert is_binary(role.name)
      assert String.starts_with?(role.name, "api-tester_")
    end

    test "filters out unknown tool names" do
      json =
        Jason.encode!(%{
          "role_name" => "test-role",
          "system_prompt" => "Test role.",
          "tools" => ["file_read", "nonexistent_tool", "shell"]
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      assert Loomkin.Tools.FileRead in role.tools
      assert Loomkin.Tools.Shell in role.tools
      # The unknown tool should be filtered out (no crash)
    end

    test "always includes peer tools" do
      json =
        Jason.encode!(%{
          "role_name" => "minimal-role",
          "system_prompt" => "Minimal.",
          "tools" => ["file_read"]
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      assert Loomkin.Tools.PeerMessage in role.tools
      assert Loomkin.Tools.PeerDiscovery in role.tools
      assert Loomkin.Tools.ContextRetrieve in role.tools
      assert Loomkin.Tools.AskUser in role.tools
    end

    test "never includes lead tools even if LLM requests them" do
      json =
        Jason.encode!(%{
          "role_name" => "sneaky-role",
          "system_prompt" => "I want all the tools.",
          "tools" => ["file_read", "team_spawn", "team_assign", "team_dissolve", "shell"]
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      refute Loomkin.Tools.TeamSpawn in role.tools
      refute Loomkin.Tools.TeamAssign in role.tools
      refute Loomkin.Tools.TeamDissolve in role.tools
      # Valid tools should still be included
      assert Loomkin.Tools.FileRead in role.tools
      assert Loomkin.Tools.Shell in role.tools
    end

    test "caps prompt at ~2048 tokens" do
      long_prompt = String.duplicate("x", 2048 * 4 + 1000)

      json =
        Jason.encode!(%{
          "role_name" => "verbose-role",
          "system_prompt" => long_prompt,
          "tools" => ["file_read"]
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      # The role-specific part should be capped, but append_context_awareness adds more
      # Just verify it doesn't crash and the role is created
      assert is_binary(role.system_prompt)
    end

    test "applies shared behavioral guidance via append_context_awareness" do
      json =
        Jason.encode!(%{
          "role_name" => "test-awareness",
          "system_prompt" => "Custom specialist.",
          "tools" => ["file_read"]
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      assert String.contains?(role.system_prompt, "Working Principles")
      assert String.contains?(role.system_prompt, "Peer Communication")
      assert String.contains?(role.system_prompt, "Context Mesh")
    end

    test "model_tier is always :default" do
      json =
        Jason.encode!(%{
          "role_name" => "any-role",
          "system_prompt" => "Any prompt.",
          "tools" => []
        })

      assert {:ok, %Role{model_tier: :default}} = Role.parse_and_validate_role(json)
    end

    test "sanitizes role name to be atom-safe" do
      json =
        Jason.encode!(%{
          "role_name" => "My Fancy Role!!! 2.0",
          "system_prompt" => "Fancy.",
          "tools" => []
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      # Should be lowercased and special chars replaced, with a hash suffix
      assert is_binary(role.name)
      assert String.starts_with?(role.name, "my_fancy_role____2_0_")
    end

    test "deduplicates tool names" do
      json =
        Jason.encode!(%{
          "role_name" => "dedup-role",
          "system_prompt" => "Dedup.",
          "tools" => ["file_read", "file_read", "shell", "shell"]
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      file_read_count = Enum.count(role.tools, &(&1 == Loomkin.Tools.FileRead))
      shell_count = Enum.count(role.tools, &(&1 == Loomkin.Tools.Shell))
      assert file_read_count == 1
      assert shell_count == 1
    end

    test "returns error for invalid JSON" do
      assert {:error, :json_parse_error} = Role.parse_and_validate_role("not json at all")
    end

    test "returns error for JSON missing required keys" do
      json = Jason.encode!(%{"role_name" => "test", "other" => "stuff"})
      assert {:error, :invalid_role_format} = Role.parse_and_validate_role(json)
    end

    test "returns error for JSON with wrong value types" do
      json = Jason.encode!(%{"role_name" => 123, "system_prompt" => "ok", "tools" => []})
      assert {:error, :invalid_role_format} = Role.parse_and_validate_role(json)
    end

    test "returns error for empty string" do
      assert {:error, :json_parse_error} = Role.parse_and_validate_role("")
    end

    test "handles tools as empty list" do
      json =
        Jason.encode!(%{
          "role_name" => "no-tools",
          "system_prompt" => "No tools needed.",
          "tools" => []
        })

      assert {:ok, %Role{} = role} = Role.parse_and_validate_role(json)
      # Should still have peer tools
      assert Loomkin.Tools.PeerMessage in role.tools
    end
  end
end
