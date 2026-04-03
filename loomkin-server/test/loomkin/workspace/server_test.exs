defmodule Loomkin.Workspace.ServerTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Repo
  alias Loomkin.Workspace
  alias Loomkin.Workspace.Server
  alias Loomkin.Workspace.TaskJournalEntry

  setup do
    {:ok, workspace} =
      %Workspace{}
      |> Workspace.changeset(%{name: "test-ws", project_paths: ["/tmp/test-project"]})
      |> Repo.insert()

    %{workspace: workspace}
  end

  describe "start_link/1" do
    test "starts with a valid workspace", %{workspace: workspace} do
      pid = start_supervised!({Server, workspace_id: workspace.id}, restart: :temporary)

      assert Process.alive?(pid)
    end

    test "fails for nonexistent workspace" do
      old = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, old) end)

      assert {:error, :workspace_not_found} =
               Server.start_link(workspace_id: Ecto.UUID.generate())
    end
  end

  describe "find_or_start/1" do
    test "creates and starts a new workspace for unknown project" do
      assert {:ok, pid, workspace_id} =
               Server.find_or_start(%{project_path: "/tmp/brand-new-project"})

      assert Process.alive?(pid)
      assert is_binary(workspace_id)

      # Verify DB record
      ws = Repo.get!(Workspace, workspace_id)
      assert ws.name == "brand-new-project"
      assert ws.project_paths == ["/tmp/brand-new-project"]
      assert ws.status == :active
    end

    test "returns existing server for known project", %{workspace: workspace} do
      # Start the server first
      start_supervised!({Server, workspace_id: workspace.id}, restart: :temporary)

      assert {:ok, _pid, ws_id} =
               Server.find_or_start(%{project_path: "/tmp/test-project"})

      assert ws_id == workspace.id
    end
  end

  describe "attach_session/2 and detach_session/2" do
    test "tracks session attachment", %{workspace: workspace} do
      start_supervised!({Server, workspace_id: workspace.id}, restart: :temporary)

      assert :ok = Server.attach_session(workspace.id, "session-1")
      assert :ok = Server.attach_session(workspace.id, "session-2")

      {:ok, state} = Server.get_state(workspace.id)
      assert state.session_count == 2

      assert :ok = Server.detach_session(workspace.id, "session-1")

      {:ok, state} = Server.get_state(workspace.id)
      assert state.session_count == 1
    end
  end

  describe "set_team_id/2 and get_team_id/1" do
    test "persists team_id to DB", %{workspace: workspace} do
      start_supervised!({Server, workspace_id: workspace.id}, restart: :temporary)

      assert nil == Server.get_team_id(workspace.id)

      :ok = Server.set_team_id(workspace.id, "team-xyz-123")
      assert "team-xyz-123" == Server.get_team_id(workspace.id)

      # Verify persisted to DB
      ws = Repo.get!(Workspace, workspace.id)
      assert ws.team_id == "team-xyz-123"
    end
  end

  describe "journal_task/2" do
    test "records a task journal entry", %{workspace: workspace} do
      start_supervised!({Server, workspace_id: workspace.id}, restart: :temporary)

      task_id = Ecto.UUID.generate()

      assert {:ok, entry} =
               Server.journal_task(workspace.id, %{
                 task_id: task_id,
                 status: "in_progress",
                 result_summary: "working on it",
                 checkpoint_json: %{"title" => "Fix bug"}
               })

      assert entry.workspace_id == workspace.id
      assert entry.task_id == task_id
      assert entry.status == "in_progress"

      # Verify persisted
      assert Repo.get!(TaskJournalEntry, entry.id)
    end
  end

  describe "hibernate/1" do
    test "updates status and stops the server", %{workspace: workspace} do
      pid =
        start_supervised!({Server, workspace_id: workspace.id}, restart: :temporary)

      ref = Process.monitor(pid)
      assert :ok = Server.hibernate(workspace.id)

      # Wait for process to fully terminate
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      # Registry cleanup is async (separate :DOWN handler) — give it a moment
      Process.sleep(50)

      # Server should be stopped
      refute Server.alive?(workspace.id)

      # DB should reflect hibernated status
      ws = Repo.get!(Workspace, workspace.id)
      assert ws.status == :hibernated
    end
  end

  describe "alive?/1" do
    test "returns true for running server", %{workspace: workspace} do
      start_supervised!({Server, workspace_id: workspace.id}, restart: :temporary)

      assert Server.alive?(workspace.id)
    end

    test "returns false for non-running server" do
      refute Server.alive?(Ecto.UUID.generate())
    end
  end
end
