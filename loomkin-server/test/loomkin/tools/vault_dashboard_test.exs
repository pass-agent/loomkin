defmodule Loomkin.Tools.VaultDashboardTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultDashboard
  alias Loomkin.Tools.VaultKanban
  alias Loomkin.Vault

  @vault_id "vault-dashboard-tool-test"

  setup do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_dashboard_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: @vault_id,
        name: "Dashboard Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_root}
      })

    %{root: tmp_root}
  end

  describe "index dashboard" do
    test "returns structured summary with entry counts", %{root: _root} do
      Vault.write(
        @vault_id,
        "notes/idea.md",
        "---\ntitle: An Idea\ntype: note\n---\nSome content"
      )

      Vault.write(
        @vault_id,
        "meetings/standup.md",
        "---\ntitle: Standup\ntype: meeting\ndate: 2026-04-01\n---\nMeeting notes"
      )

      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "index", days: 30},
                 %{}
               )

      assert result =~ "Vault Dashboard"
      assert result =~ "Total entries: 2"
      assert result =~ "note"
      assert result =~ "meeting"
    end

    test "includes active kanban items", %{root: _root} do
      VaultKanban.run(
        %{
          vault_id: @vault_id,
          action: "add",
          description: "Active task",
          column: "in_progress"
        },
        %{}
      )

      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "index"},
                 %{}
               )

      assert result =~ "Active task"
    end

    test "handles empty vault" do
      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "index"},
                 %{}
               )

      assert result =~ "Total entries: 0"
      assert result =~ "No active tasks"
    end
  end

  describe "activity dashboard" do
    test "returns recent entries grouped by date", %{root: _root} do
      Vault.write(
        @vault_id,
        "notes/today.md",
        "---\ntitle: Today Note\ntype: note\n---\nContent"
      )

      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "activity", days: 7},
                 %{}
               )

      assert result =~ "Activity"
      assert result =~ "Today Note"
    end

    test "returns empty message when no activity" do
      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "activity", days: 7},
                 %{}
               )

      assert result =~ "No activity"
    end
  end

  describe "updates_hub" do
    test "returns checkin summaries grouped by author", %{root: _root} do
      Vault.write(
        @vault_id,
        "checkins/alice-01.md",
        "---\ntitle: Alice Checkin\ntype: checkin\ndate: 2026-04-01\nauthor: Alice\n---\nDoing great"
      )

      Vault.write(
        @vault_id,
        "checkins/bob-01.md",
        "---\ntitle: Bob Checkin\ntype: checkin\ndate: 2026-04-01\nauthor: Bob\n---\nShipping things"
      )

      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "updates_hub", days: 30},
                 %{}
               )

      assert result =~ "Updates Hub"
      assert result =~ "Alice"
      assert result =~ "Bob"
    end

    test "filters by person", %{root: _root} do
      Vault.write(
        @vault_id,
        "checkins/alice-02.md",
        "---\ntitle: Alice Update\ntype: checkin\ndate: 2026-04-01\nauthor: Alice\n---\nStuff"
      )

      Vault.write(
        @vault_id,
        "checkins/bob-02.md",
        "---\ntitle: Bob Update\ntype: checkin\ndate: 2026-04-01\nauthor: Bob\n---\nThings"
      )

      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "updates_hub", days: 30, person: "Alice"},
                 %{}
               )

      assert result =~ "Alice"
      refute result =~ "Bob"
    end
  end

  describe "kanban_summary" do
    test "returns column counts and in-progress items" do
      VaultKanban.run(
        %{vault_id: @vault_id, action: "add", description: "Backlog item", column: "backlog"},
        %{}
      )

      VaultKanban.run(
        %{
          vault_id: @vault_id,
          action: "add",
          description: "Active item",
          column: "in_progress",
          assignee: "alice"
        },
        %{}
      )

      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "kanban_summary"},
                 %{}
               )

      assert result =~ "Kanban Summary"
      assert result =~ "Total active: 2"
      assert result =~ "Active item"
      assert result =~ "alice"
    end

    test "includes project tag breakdown" do
      VaultKanban.run(
        %{
          vault_id: @vault_id,
          action: "add",
          description: "TCS work",
          project_tag: "tcs"
        },
        %{}
      )

      VaultKanban.run(
        %{
          vault_id: @vault_id,
          action: "add",
          description: "BTRW work",
          project_tag: "btrw"
        },
        %{}
      )

      assert {:ok, %{result: result}} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "kanban_summary"},
                 %{}
               )

      assert result =~ "tcs"
      assert result =~ "btrw"
    end
  end

  describe "error handling" do
    test "returns error for unknown dashboard type" do
      assert {:error, msg} =
               VaultDashboard.run(
                 %{vault_id: @vault_id, dashboard_type: "invalid"},
                 %{}
               )

      assert msg =~ "Unknown dashboard type"
    end
  end
end
