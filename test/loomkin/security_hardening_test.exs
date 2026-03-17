defmodule Loomkin.SecurityHardeningTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Session.Persistence
  alias Loomkin.ShellCommand

  import Loomkin.AccountsFixtures

  describe "user-scoped session queries" do
    setup do
      user_a = user_fixture()
      user_b = user_fixture()

      {:ok, session_a} =
        Persistence.create_session(%{
          model: "test:model",
          project_path: "/tmp/project-a",
          user_id: user_a.id
        })

      {:ok, session_b} =
        Persistence.create_session(%{
          model: "test:model",
          project_path: "/tmp/project-a",
          user_id: user_b.id
        })

      %{user_a: user_a, user_b: user_b, session_a: session_a, session_b: session_b}
    end

    test "list_sessions scoped to user", %{
      user_a: user_a,
      session_a: session_a,
      session_b: session_b
    } do
      sessions = Persistence.list_sessions(user: user_a)
      session_ids = Enum.map(sessions, & &1.id)

      assert session_a.id in session_ids
      refute session_b.id in session_ids
    end

    test "list_projects scoped to user", %{user_a: user_a, user_b: user_b} do
      # Both users have sessions on /tmp/project-a
      projects_a = Persistence.list_projects(user: user_a)
      projects_b = Persistence.list_projects(user: user_b)

      assert length(projects_a) == 1
      assert length(projects_b) == 1
      assert hd(projects_a).session_count == 1
      assert hd(projects_b).session_count == 1
    end

    test "find_latest_active_session scoped to user", %{
      user_a: user_a,
      user_b: user_b,
      session_a: session_a,
      session_b: session_b
    } do
      latest = Persistence.find_latest_active_session("/tmp/project-a", user: user_a)
      assert latest.id == session_a.id

      latest_b = Persistence.find_latest_active_session("/tmp/project-a", user: user_b)
      assert latest_b.id == session_b.id
    end

    test "list_sessions_for_project scoped to user", %{
      user_a: user_a,
      session_a: session_a,
      session_b: session_b
    } do
      sessions = Persistence.list_sessions_for_project("/tmp/project-a", user: user_a)
      session_ids = Enum.map(sessions, & &1.id)

      assert session_a.id in session_ids
      refute session_b.id in session_ids
    end

    test "unscoped queries return all sessions when user is nil", %{
      session_a: session_a,
      session_b: session_b
    } do
      sessions = Persistence.list_sessions()
      session_ids = Enum.map(sessions, & &1.id)

      assert session_a.id in session_ids
      assert session_b.id in session_ids
    end
  end

  describe "shell command injection guard" do
    test "rejects semicolon chaining" do
      assert {:error, _} = ShellCommand.validate_command("mix test; echo pwned")
    end

    test "rejects && chaining" do
      assert {:error, _} = ShellCommand.validate_command("mix test && echo pwned")
    end

    test "rejects || chaining" do
      assert {:error, _} = ShellCommand.validate_command("mix test || echo pwned")
    end

    test "rejects pipe" do
      assert {:error, _} = ShellCommand.validate_command("mix test | cat")
    end

    test "rejects backtick substitution" do
      assert {:error, _} = ShellCommand.validate_command("mix test `whoami`")
    end

    test "rejects $() substitution" do
      assert {:error, _} = ShellCommand.validate_command("mix test $(whoami)")
    end

    test "rejects output redirection" do
      assert {:error, _} = ShellCommand.validate_command("mix test > /tmp/out")
    end

    test "rejects input redirection" do
      assert {:error, _} = ShellCommand.validate_command("mix test < /tmp/in")
    end

    test "allows safe commands" do
      assert :ok = ShellCommand.validate_command("mix test")
      assert :ok = ShellCommand.validate_command("mix test test/my_test.exs")
      assert :ok = ShellCommand.validate_command("elixir -e 'IO.puts(1)'")
    end

    test "rejects newline chaining" do
      assert {:error, _} = ShellCommand.validate_command("mix test\necho pwned")
      assert {:error, _} = ShellCommand.validate_command("mix test\r\necho pwned")
    end

    test "rejects disallowed prefix" do
      assert {:error, _} = ShellCommand.validate_command("rm -rf /")
      assert {:error, _} = ShellCommand.validate_command("curl evil.com")
    end
  end
end
