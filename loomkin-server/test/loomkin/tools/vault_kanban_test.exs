defmodule Loomkin.Tools.VaultKanbanTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Tools.VaultKanban
  alias Loomkin.Vault

  setup do
    vault_id = "vault-kanban-test-#{System.unique_integer([:positive])}"

    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "loomkin_vault_kanban_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, _config} =
      Vault.create_vault(%{
        vault_id: vault_id,
        name: "Kanban Test Vault",
        storage_type: "local",
        storage_config: %{"root" => tmp_root}
      })

    %{root: tmp_root, vault_id: vault_id}
  end

  describe "add" do
    test "creates a kanban item with defaults", %{vault_id: vault_id} do
      params = %{
        vault_id: vault_id,
        action: "add",
        description: "Write the quarterly report"
      }

      assert {:ok, %{result: result}} = VaultKanban.run(params, %{})
      assert result =~ "Created task"
      assert result =~ "Write the quarterly report"
      assert result =~ "backlog"
    end

    test "creates a kanban item with all fields", %{vault_id: vault_id} do
      params = %{
        vault_id: vault_id,
        action: "add",
        description: "Review PR #42",
        assignee: "alice",
        project_tag: "tcs",
        column: "in_progress",
        source_path: "meetings/2026-04-01.md"
      }

      assert {:ok, %{result: result}} = VaultKanban.run(params, %{})
      assert result =~ "Created task"
      assert result =~ "Review PR #42"
      assert result =~ "in_progress"
      assert result =~ "alice"
      assert result =~ "tcs"
    end
  end

  describe "complete" do
    test "marks item done with timestamp", %{vault_id: vault_id} do
      {:ok, %{result: add_result}} =
        VaultKanban.run(
          %{vault_id: vault_id, action: "add", description: "Finish docs"},
          %{}
        )

      task_id = extract_task_id(add_result)

      assert {:ok, %{result: result}} =
               VaultKanban.run(
                 %{vault_id: vault_id, action: "complete", task_id: task_id},
                 %{}
               )

      assert result =~ "Completed"
      assert result =~ "Finish docs"

      # Verify via list that it shows as done
      assert {:ok, %{result: list_result}} =
               VaultKanban.run(
                 %{vault_id: vault_id, action: "list", filter_column: "done"},
                 %{}
               )

      assert list_result =~ "Finish docs"
    end

    test "returns error for missing task", %{vault_id: vault_id} do
      assert {:error, msg} =
               VaultKanban.run(
                 %{
                   vault_id: vault_id,
                   action: "complete",
                   task_id: "00000000-0000-0000-0000-000000000000"
                 },
                 %{}
               )

      assert msg =~ "not found"
    end
  end

  describe "move" do
    test "changes column", %{vault_id: vault_id} do
      {:ok, %{result: add_result}} =
        VaultKanban.run(
          %{vault_id: vault_id, action: "add", description: "Deploy v2"},
          %{}
        )

      task_id = extract_task_id(add_result)

      assert {:ok, %{result: result}} =
               VaultKanban.run(
                 %{vault_id: vault_id, action: "move", task_id: task_id, column: "in_progress"},
                 %{}
               )

      assert result =~ "Moved"
      assert result =~ "in_progress"
    end

    test "returns error for invalid column", %{vault_id: vault_id} do
      {:ok, %{result: add_result}} =
        VaultKanban.run(
          %{vault_id: vault_id, action: "add", description: "Test task"},
          %{}
        )

      task_id = extract_task_id(add_result)

      assert {:error, msg} =
               VaultKanban.run(
                 %{vault_id: vault_id, action: "move", task_id: task_id, column: "invalid"},
                 %{}
               )

      assert msg =~ "Invalid column"
    end
  end

  describe "list" do
    test "returns items grouped by column", %{vault_id: vault_id} do
      VaultKanban.run(
        %{vault_id: vault_id, action: "add", description: "Task A", column: "backlog"},
        %{}
      )

      VaultKanban.run(
        %{vault_id: vault_id, action: "add", description: "Task B", column: "in_progress"},
        %{}
      )

      assert {:ok, %{result: result}} =
               VaultKanban.run(%{vault_id: vault_id, action: "list"}, %{})

      assert result =~ "2 tasks"
      assert result =~ "Task A"
      assert result =~ "Task B"
    end

    test "respects assignee filter", %{vault_id: vault_id} do
      VaultKanban.run(
        %{
          vault_id: vault_id,
          action: "add",
          description: "Alice task",
          assignee: "alice"
        },
        %{}
      )

      VaultKanban.run(
        %{
          vault_id: vault_id,
          action: "add",
          description: "Bob task",
          assignee: "bob"
        },
        %{}
      )

      assert {:ok, %{result: result}} =
               VaultKanban.run(
                 %{vault_id: vault_id, action: "list", filter_assignee: "alice"},
                 %{}
               )

      assert result =~ "Alice task"
      refute result =~ "Bob task"
    end

    test "respects project filter", %{vault_id: vault_id} do
      VaultKanban.run(
        %{
          vault_id: vault_id,
          action: "add",
          description: "TCS item",
          project_tag: "tcs"
        },
        %{}
      )

      VaultKanban.run(
        %{
          vault_id: vault_id,
          action: "add",
          description: "BTRW item",
          project_tag: "btrw"
        },
        %{}
      )

      assert {:ok, %{result: result}} =
               VaultKanban.run(
                 %{vault_id: vault_id, action: "list", filter_project: "tcs"},
                 %{}
               )

      assert result =~ "TCS item"
      refute result =~ "BTRW item"
    end

    test "returns empty message when no tasks", %{vault_id: vault_id} do
      assert {:ok, %{result: result}} =
               VaultKanban.run(%{vault_id: vault_id, action: "list"}, %{})

      assert result =~ "No tasks found"
    end
  end

  describe "archive" do
    test "moves done items to archived", %{vault_id: vault_id} do
      {:ok, %{result: add_result}} =
        VaultKanban.run(
          %{vault_id: vault_id, action: "add", description: "Archive me"},
          %{}
        )

      task_id = extract_task_id(add_result)

      VaultKanban.run(
        %{vault_id: vault_id, action: "complete", task_id: task_id},
        %{}
      )

      assert {:ok, %{result: result}} =
               VaultKanban.run(%{vault_id: vault_id, action: "archive"}, %{})

      assert result =~ "Archived 1 completed"

      # Archived items should not appear in list
      assert {:ok, %{result: list_result}} =
               VaultKanban.run(%{vault_id: vault_id, action: "list"}, %{})

      assert list_result =~ "No tasks found"
    end
  end

  describe "search" do
    test "fuzzy matches descriptions", %{vault_id: vault_id} do
      VaultKanban.run(
        %{vault_id: vault_id, action: "add", description: "Implement authentication flow"},
        %{}
      )

      VaultKanban.run(
        %{vault_id: vault_id, action: "add", description: "Write unit tests"},
        %{}
      )

      assert {:ok, %{result: result}} =
               VaultKanban.run(
                 %{vault_id: vault_id, action: "search", search_term: "authentication"},
                 %{}
               )

      assert result =~ "authentication"
    end
  end

  # Extract task ID from "Created task <uuid>" result string
  defp extract_task_id(result) do
    [_, id] = Regex.run(~r/Created task ([a-f0-9-]+)/, result)
    id
  end
end
