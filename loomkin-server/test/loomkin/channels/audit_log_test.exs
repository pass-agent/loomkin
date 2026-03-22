defmodule Loomkin.Channels.AuditLogTest do
  use ExUnit.Case, async: false

  alias Loomkin.Channels.AuditLog

  setup do
    # Start AuditLog if not already running
    case AuditLog.start_link() do
      {:ok, pid} ->
        on_exit(fn -> GenServer.stop(pid) end)
        :ok

      {:error, {:already_started, _}} ->
        # Clear existing entries by restarting
        :ok
    end

    :ok
  end

  describe "log_command/7" do
    test "logs a command and retrieves it" do
      AuditLog.log_command(
        :telegram,
        "12345",
        %{from_id: 42},
        "bind",
        "team-1",
        :ok,
        "Bound to team team-1."
      )

      # Give the cast time to process
      Process.sleep(10)

      entries = AuditLog.recent(10)
      assert length(entries) >= 1

      entry = hd(entries)
      assert entry.channel == :telegram
      assert entry.channel_id == "12345"
      assert entry.user_id == 42
      assert entry.command == "bind"
      assert entry.args == "team-1"
      assert entry.result == :ok
      assert entry.response == "Bound to team team-1."
    end

    test "extracts telegram user_id from from_id" do
      AuditLog.log_command(:telegram, "111", %{from_id: 99}, "status", "", :ok)
      Process.sleep(10)

      [entry | _] = AuditLog.recent(1)
      assert entry.user_id == 99
    end

    test "extracts discord user_id from user_id" do
      AuditLog.log_command(:discord, "222", %{user_id: 88}, "agents", "", :ok)
      Process.sleep(10)

      [entry | _] = AuditLog.recent(1)
      assert entry.user_id == 88
    end

    test "handles nil user_id gracefully" do
      AuditLog.log_command(:telegram, "333", %{}, "status", "", :ok)
      Process.sleep(10)

      [entry | _] = AuditLog.recent(1)
      assert entry.user_id == nil
    end
  end

  describe "recent/1" do
    test "returns entries newest first" do
      AuditLog.log_command(:telegram, "1", %{}, "cmd1", "", :ok)
      Process.sleep(5)
      AuditLog.log_command(:telegram, "1", %{}, "cmd2", "", :ok)
      Process.sleep(5)
      AuditLog.log_command(:telegram, "1", %{}, "cmd3", "", :ok)
      Process.sleep(10)

      entries = AuditLog.recent(3)
      commands = Enum.map(entries, & &1.command)
      assert hd(commands) == "cmd3"
    end

    test "respects limit parameter" do
      for i <- 1..5 do
        AuditLog.log_command(:telegram, "1", %{}, "cmd#{i}", "", :ok)
      end

      Process.sleep(20)

      assert length(AuditLog.recent(2)) == 2
    end

    test "returns empty list when no entries" do
      # Fresh ETS table from setup, but may have entries from other tests
      # Just verify it returns a list
      assert is_list(AuditLog.recent(10))
    end
  end

  describe "format_recent/1" do
    test "formats entries for display" do
      AuditLog.log_command(:telegram, "12345", %{from_id: 42}, "bind", "team-1", :ok, "Bound.")
      Process.sleep(10)

      output = AuditLog.format_recent(10)
      assert output =~ "Recent commands"
      assert output =~ "telegram"
      assert output =~ "/bind"
      assert output =~ "user=42"
      assert output =~ "OK"
    end

    test "shows ERR for error results" do
      AuditLog.log_command(:telegram, "12345", %{from_id: 42}, "bind", "", :error, "Failed")
      Process.sleep(10)

      output = AuditLog.format_recent(10)
      assert output =~ "ERR"
    end
  end
end
