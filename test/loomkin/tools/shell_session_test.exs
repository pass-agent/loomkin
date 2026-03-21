defmodule Loomkin.Tools.ShellSessionTest do
  use ExUnit.Case, async: false

  alias Loomkin.Tools.Shell
  alias Loomkin.Tools.ShellSession

  setup do
    key = {"test_team_#{System.unique_integer([:positive])}", :test_agent}
    on_exit(fn -> ShellSession.cleanup(key) end)
    %{key: key}
  end

  # --- ShellSession unit tests ---

  describe "init_session/2" do
    test "creates session with project path as cwd", %{key: key} do
      assert :ok = ShellSession.init_session(key, "/tmp/project")
      assert %{cwd: "/tmp/project", env: %{}} = ShellSession.get(key)
    end

    test "is a no-op if session already exists", %{key: key} do
      ShellSession.init_session(key, "/tmp/first")
      ShellSession.init_session(key, "/tmp/second")
      assert %{cwd: "/tmp/first"} = ShellSession.get(key)
    end
  end

  describe "get/1" do
    test "returns nil for unknown key" do
      assert nil == ShellSession.get({"nonexistent", :agent})
    end
  end

  describe "get_cwd/2" do
    test "returns default when no session exists" do
      assert "/fallback" == ShellSession.get_cwd({"missing", :agent}, "/fallback")
    end

    test "returns stored cwd when session exists", %{key: key} do
      ShellSession.init_session(key, "/tmp/stored")
      assert "/tmp/stored" == ShellSession.get_cwd(key, "/fallback")
    end
  end

  describe "update_cwd/2" do
    test "updates cwd on existing session", %{key: key} do
      ShellSession.init_session(key, "/tmp/old")
      ShellSession.update_cwd(key, "/tmp/new")
      assert %{cwd: "/tmp/new"} = ShellSession.get(key)
    end

    test "creates session if none exists", %{key: key} do
      ShellSession.update_cwd(key, "/tmp/fresh")
      assert %{cwd: "/tmp/fresh", env: %{}} = ShellSession.get(key)
    end

    test "preserves env when updating cwd", %{key: key} do
      ShellSession.init_session(key, "/tmp/proj")
      ShellSession.merge_env(key, %{"FOO" => "bar"})
      ShellSession.update_cwd(key, "/tmp/proj/sub")
      assert %{cwd: "/tmp/proj/sub", env: %{"FOO" => "bar"}} = ShellSession.get(key)
    end
  end

  describe "merge_env/2" do
    test "adds env vars to session", %{key: key} do
      ShellSession.init_session(key, "/tmp/proj")
      ShellSession.merge_env(key, %{"FOO" => "bar", "BAZ" => "qux"})
      assert %{"FOO" => "bar", "BAZ" => "qux"} = ShellSession.get_env(key)
    end

    test "merges with existing env vars", %{key: key} do
      ShellSession.init_session(key, "/tmp/proj")
      ShellSession.merge_env(key, %{"A" => "1"})
      ShellSession.merge_env(key, %{"B" => "2"})
      assert %{"A" => "1", "B" => "2"} = ShellSession.get_env(key)
    end

    test "overwrites existing keys", %{key: key} do
      ShellSession.init_session(key, "/tmp/proj")
      ShellSession.merge_env(key, %{"A" => "1"})
      ShellSession.merge_env(key, %{"A" => "2"})
      assert %{"A" => "2"} = ShellSession.get_env(key)
    end

    test "is a no-op for empty map", %{key: key} do
      ShellSession.init_session(key, "/tmp/proj")
      assert :ok = ShellSession.merge_env(key, %{})
    end
  end

  describe "cleanup/1" do
    test "removes session", %{key: key} do
      ShellSession.init_session(key, "/tmp/proj")
      ShellSession.cleanup(key)
      assert nil == ShellSession.get(key)
    end

    test "is safe for nonexistent keys" do
      assert :ok = ShellSession.cleanup({"nonexistent", :agent})
    end
  end

  describe "extract_exports/1" do
    test "extracts single export" do
      assert %{"FOO" => "bar"} = ShellSession.extract_exports("export FOO=bar")
    end

    test "extracts multiple exports" do
      assert %{"A" => "1", "B" => "2"} =
               ShellSession.extract_exports("export A=1 && export B=2")
    end

    test "handles double-quoted values" do
      assert %{"MSG" => "hello world"} =
               ShellSession.extract_exports(~s(export MSG="hello world"))
    end

    test "handles single-quoted values" do
      assert %{"MSG" => "hello world"} =
               ShellSession.extract_exports("export MSG='hello world'")
    end

    test "returns empty map for commands without exports" do
      assert %{} == ShellSession.extract_exports("echo hello")
    end
  end

  describe "extract_cwd_from_output/1" do
    test "extracts cwd after sentinel" do
      output = "some output\n__LOOMKIN_CWD__\n/tmp/new/path\n"
      assert {"some output", "/tmp/new/path"} = ShellSession.extract_cwd_from_output(output)
    end

    test "returns nil cwd when sentinel not found" do
      output = "just regular output"
      assert {"just regular output", nil} = ShellSession.extract_cwd_from_output(output)
    end

    test "handles output with trailing content after cwd" do
      output = "line1\n__LOOMKIN_CWD__\n/the/path\nextra stuff\n"
      {cleaned, cwd} = ShellSession.extract_cwd_from_output(output)
      assert cwd == "/the/path"
      assert cleaned =~ "line1"
    end
  end

  describe "wrap_command_for_cwd_tracking/1" do
    test "appends sentinel and pwd" do
      assert "echo hi ; echo __LOOMKIN_CWD__ ; pwd" =
               ShellSession.wrap_command_for_cwd_tracking("echo hi")
    end
  end

  # --- Integration tests: Shell tool with session persistence ---

  describe "shell tool cwd persistence" do
    @tag :tmp_dir
    test "cd in one command persists to next command", %{tmp_dir: proj} do
      File.mkdir_p!(Path.join(proj, "subdir"))
      File.write!(Path.join(proj, "subdir/marker.txt"), "found_it")

      team_id = "session_test_#{System.unique_integer([:positive])}"
      agent_name = :cwd_agent
      context = %{project_path: proj, team_id: team_id, agent_name: agent_name}

      on_exit(fn -> ShellSession.cleanup({team_id, agent_name}) end)

      # First command: cd into subdir
      assert {:ok, _} = Shell.run(%{"command" => "cd subdir"}, context)

      # Second command: should be in subdir now
      assert {:ok, %{result: result}} = Shell.run(%{"command" => "cat marker.txt"}, context)
      assert result =~ "found_it"
    end

    @tag :tmp_dir
    test "cwd tracking works across multiple cd commands", %{tmp_dir: proj} do
      File.mkdir_p!(Path.join(proj, "a/b/c"))
      File.write!(Path.join(proj, "a/b/c/deep.txt"), "deep_value")

      team_id = "multi_cd_#{System.unique_integer([:positive])}"
      agent_name = :multi_cd_agent
      context = %{project_path: proj, team_id: team_id, agent_name: agent_name}

      on_exit(fn -> ShellSession.cleanup({team_id, agent_name}) end)

      Shell.run(%{"command" => "cd a"}, context)
      Shell.run(%{"command" => "cd b"}, context)
      Shell.run(%{"command" => "cd c"}, context)

      assert {:ok, %{result: result}} = Shell.run(%{"command" => "cat deep.txt"}, context)
      assert result =~ "deep_value"
    end

    @tag :tmp_dir
    test "different agents have independent sessions", %{tmp_dir: proj} do
      File.mkdir_p!(Path.join(proj, "agent1_dir"))
      File.mkdir_p!(Path.join(proj, "agent2_dir"))
      File.write!(Path.join(proj, "agent1_dir/a1.txt"), "agent1")
      File.write!(Path.join(proj, "agent2_dir/a2.txt"), "agent2")

      team_id = "iso_test_#{System.unique_integer([:positive])}"
      ctx1 = %{project_path: proj, team_id: team_id, agent_name: :agent1}
      ctx2 = %{project_path: proj, team_id: team_id, agent_name: :agent2}

      on_exit(fn ->
        ShellSession.cleanup({team_id, :agent1})
        ShellSession.cleanup({team_id, :agent2})
      end)

      Shell.run(%{"command" => "cd agent1_dir"}, ctx1)
      Shell.run(%{"command" => "cd agent2_dir"}, ctx2)

      assert {:ok, %{result: r1}} = Shell.run(%{"command" => "cat a1.txt"}, ctx1)
      assert r1 =~ "agent1"

      assert {:ok, %{result: r2}} = Shell.run(%{"command" => "cat a2.txt"}, ctx2)
      assert r2 =~ "agent2"
    end

    @tag :tmp_dir
    test "works without team_id/agent_name (falls back to project_path)", %{tmp_dir: proj} do
      context = %{project_path: proj}

      assert {:ok, %{result: result}} = Shell.run(%{"command" => "echo hello"}, context)
      assert result =~ "hello"
    end
  end

  describe "shell tool env persistence" do
    @tag :tmp_dir
    test "exported env vars persist to next command", %{tmp_dir: proj} do
      team_id = "env_test_#{System.unique_integer([:positive])}"
      agent_name = :env_agent
      context = %{project_path: proj, team_id: team_id, agent_name: agent_name}

      on_exit(fn -> ShellSession.cleanup({team_id, agent_name}) end)

      Shell.run(%{"command" => "export MY_VAR=hello_world"}, context)

      assert {:ok, %{result: result}} = Shell.run(%{"command" => "echo $MY_VAR"}, context)
      assert result =~ "hello_world"
    end

    @tag :tmp_dir
    test "multiple exports accumulate", %{tmp_dir: proj} do
      team_id = "multi_env_#{System.unique_integer([:positive])}"
      agent_name = :multi_env_agent
      context = %{project_path: proj, team_id: team_id, agent_name: agent_name}

      on_exit(fn -> ShellSession.cleanup({team_id, agent_name}) end)

      Shell.run(%{"command" => "export A=first"}, context)
      Shell.run(%{"command" => "export B=second"}, context)

      assert {:ok, %{result: result}} = Shell.run(%{"command" => "echo $A $B"}, context)
      assert result =~ "first second"
    end
  end

  describe "session cleanup on agent terminate" do
    test "cleanup removes session data" do
      key = {"cleanup_team", :cleanup_agent}
      ShellSession.init_session(key, "/tmp/proj")
      ShellSession.merge_env(key, %{"FOO" => "bar"})

      assert %{cwd: "/tmp/proj", env: %{"FOO" => "bar"}} = ShellSession.get(key)

      ShellSession.cleanup(key)
      assert nil == ShellSession.get(key)
    end
  end
end
