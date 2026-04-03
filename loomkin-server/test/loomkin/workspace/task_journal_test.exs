defmodule Loomkin.Workspace.TaskJournalEntryTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Workspace
  alias Loomkin.Workspace.TaskJournalEntry

  setup do
    {:ok, workspace} =
      %Workspace{}
      |> Workspace.changeset(%{name: "test workspace"})
      |> Repo.insert()

    %{workspace: workspace}
  end

  describe "changeset/2" do
    test "valid with required fields", %{workspace: workspace} do
      changeset =
        TaskJournalEntry.changeset(%TaskJournalEntry{}, %{
          workspace_id: workspace.id,
          task_id: Ecto.UUID.generate(),
          status: "in_progress"
        })

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = TaskJournalEntry.changeset(%TaskJournalEntry{}, %{})
      refute changeset.valid?
      assert %{workspace_id: ["can't be blank"]} = errors_on(changeset)
      assert %{task_id: ["can't be blank"]} = errors_on(changeset)
      assert %{status: ["can't be blank"]} = errors_on(changeset)
    end

    test "persists with optional fields", %{workspace: workspace} do
      {:ok, entry} =
        %TaskJournalEntry{}
        |> TaskJournalEntry.changeset(%{
          workspace_id: workspace.id,
          task_id: Ecto.UUID.generate(),
          status: "completed",
          result_summary: "All tests pass",
          checkpoint_json: %{"title" => "Fix login", "owner" => "coder-1"}
        })
        |> Repo.insert()

      assert entry.result_summary == "All tests pass"
      assert entry.checkpoint_json == %{"title" => "Fix login", "owner" => "coder-1"}
    end

    test "defaults checkpoint_json to empty map", %{workspace: workspace} do
      {:ok, entry} =
        %TaskJournalEntry{}
        |> TaskJournalEntry.changeset(%{
          workspace_id: workspace.id,
          task_id: Ecto.UUID.generate(),
          status: "pending"
        })
        |> Repo.insert()

      assert entry.checkpoint_json == %{}
    end

    test "cascades delete from workspace", %{workspace: workspace} do
      task_id = Ecto.UUID.generate()

      {:ok, _entry} =
        %TaskJournalEntry{}
        |> TaskJournalEntry.changeset(%{
          workspace_id: workspace.id,
          task_id: task_id,
          status: "in_progress"
        })
        |> Repo.insert()

      Repo.delete!(workspace)

      assert Repo.all(TaskJournalEntry) == []
    end
  end
end
