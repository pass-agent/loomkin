defmodule Loomkin.Permissions.ManagerTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Permissions.Manager
  alias Loomkin.Schemas.Session

  setup do
    # Create a test session
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        model: "test:model",
        project_path: "/tmp/test"
      })
      |> Repo.insert()

    # Ensure config has defaults loaded
    Loomkin.Config.load("/tmp/nonexistent")

    %{session: session}
  end

  describe "check/3" do
    test "returns :allowed for auto-approved tools", %{session: session} do
      assert Manager.check("file_read", "/some/path", session.id) == :allowed
      assert Manager.check("content_search", "/some/path", session.id) == :allowed
      assert Manager.check("directory_list", "/some/path", session.id) == :allowed
      assert Manager.check("file_search", "/some/path", session.id) == :allowed
    end

    test "returns :ask for non-approved tools without grants", %{session: session} do
      assert Manager.check("file_write", "/some/path", session.id) == :ask
      assert Manager.check("shell", "/some/path", session.id) == :ask
      assert Manager.check("git", "/some/path", session.id) == :ask
    end

    test "returns :allowed after granting permission", %{session: session} do
      assert Manager.check("file_write", "/some/path", session.id) == :ask

      {:ok, _grant} = Manager.grant("file_write", "/some/path", session.id)

      assert Manager.check("file_write", "/some/path", session.id) == :allowed
    end

    test "wildcard grant covers any path", %{session: session} do
      {:ok, _grant} = Manager.grant("shell", "*", session.id)

      assert Manager.check("shell", "/any/path", session.id) == :allowed
      assert Manager.check("shell", "/another/path", session.id) == :allowed
    end

    test "path-specific grant only covers that path", %{session: session} do
      {:ok, _grant} = Manager.grant("file_write", "/specific/path", session.id)

      assert Manager.check("file_write", "/specific/path", session.id) == :allowed
      assert Manager.check("file_write", "/other/path", session.id) == :ask
    end
  end

  describe "auto_approved?/1" do
    test "returns true for default auto-approved tools" do
      assert Manager.auto_approved?("file_read")
      assert Manager.auto_approved?("file_search")
      assert Manager.auto_approved?("content_search")
      assert Manager.auto_approved?("directory_list")
    end

    test "returns false for write/execute tools" do
      refute Manager.auto_approved?("file_write")
      refute Manager.auto_approved?("file_edit")
      refute Manager.auto_approved?("shell")
      refute Manager.auto_approved?("git")
    end
  end

  describe "tool_category/1" do
    test "categorizes read tools" do
      assert Manager.tool_category("file_read") == :read
      assert Manager.tool_category("file_search") == :read
      assert Manager.tool_category("content_search") == :read
      assert Manager.tool_category("directory_list") == :read
    end

    test "categorizes write tools" do
      assert Manager.tool_category("file_write") == :write
      assert Manager.tool_category("file_edit") == :write
    end

    test "categorizes execute tools" do
      assert Manager.tool_category("shell") == :execute
      assert Manager.tool_category("git") == :execute
    end

    test "returns :unknown for unrecognized tools" do
      assert Manager.tool_category("unknown_tool") == :unknown
    end
  end

  describe "grant/3" do
    test "creates a permission grant record", %{session: session} do
      assert {:ok, grant} = Manager.grant("file_write", "/some/path", session.id)

      assert grant.tool == "file_write"
      assert grant.scope == "/some/path"
      assert grant.session_id == session.id
      assert grant.granted_at != nil
    end
  end

  describe "record_decision/1" do
    test "creates an audit log entry", %{session: session} do
      assert {:ok, log} =
               Manager.record_decision(%{
                 session_id: session.id,
                 team_id: "team-1",
                 agent_name: "coder-1",
                 tool_name: "file_write",
                 tool_path: "/lib/foo.ex",
                 action: :allow_once,
                 comment: "looks safe"
               })

      assert log.agent_name == "coder-1"
      assert log.tool_name == "file_write"
      assert log.action == :allow_once
      assert log.comment == "looks safe"
      assert log.decided_at != nil
    end

    test "comment is optional", %{session: session} do
      assert {:ok, log} =
               Manager.record_decision(%{
                 session_id: session.id,
                 team_id: "team-1",
                 agent_name: "coder-1",
                 tool_name: "shell",
                 action: :deny
               })

      assert log.comment == nil
    end

    test "validates action values", %{session: session} do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               Manager.record_decision(%{
                 session_id: session.id,
                 team_id: "team-1",
                 agent_name: "coder-1",
                 tool_name: "shell",
                 action: "invalid_action"
               })
    end
  end

  describe "list_recent_decisions/2" do
    test "returns decisions ordered by most recent", %{session: session} do
      actions = [:allow_once, :allow_always, :deny]

      for {action, i} <- Enum.with_index(actions) do
        decided_at =
          DateTime.utc_now()
          |> DateTime.add(i, :second)
          |> DateTime.truncate(:second)

        Manager.record_decision(%{
          session_id: session.id,
          team_id: "team-1",
          agent_name: "coder-1",
          tool_name: "file_write",
          action: action,
          decided_at: decided_at
        })
      end

      decisions = Manager.list_recent_decisions(session.id)
      assert length(decisions) == 3
      assert hd(decisions).action == :deny
    end

    test "respects limit", %{session: session} do
      for _ <- 1..5 do
        Manager.record_decision(%{
          session_id: session.id,
          team_id: "team-1",
          agent_name: "coder-1",
          tool_name: "file_write",
          action: :allow_once
        })
      end

      assert length(Manager.list_recent_decisions(session.id, 2)) == 2
    end
  end
end
