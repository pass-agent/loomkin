defmodule Loomkin.Session.SessionTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Session
  alias Loomkin.Session.{Manager, Persistence}

  # We test the GenServer by starting it through the Manager
  # and interacting via the public API.
  # LLM calls will fail (no API key), so we test session lifecycle,
  # persistence, and error handling.

  @project_path "/tmp/loom-test-project"

  setup do
    File.mkdir_p!(@project_path)
    on_exit(fn -> File.rm_rf!(@project_path) end)
    :ok
  end

  describe "start_link/1 and lifecycle" do
    test "starts a session and registers it" do
      session_id = Ecto.UUID.generate()

      {:ok, pid} =
        Manager.start_session(
          session_id: session_id,
          model: "anthropic:claude-sonnet-4-6",
          project_path: @project_path
        )

      assert Process.alive?(pid)
      assert {:ok, ^pid} = Manager.find_session(session_id)

      # DB session was created
      db_session = Persistence.get_session(session_id)
      assert db_session != nil
      assert db_session.model == "anthropic:claude-sonnet-4-6"
      assert db_session.project_path == @project_path
    end

    test "resumes an existing session" do
      session_id = Ecto.UUID.generate()

      # Create a session in the DB first
      {:ok, _} =
        Persistence.create_session(%{
          id: session_id,
          model: "anthropic:claude-sonnet-4-6",
          project_path: @project_path,
          title: "Existing session"
        })

      # Save a message
      {:ok, _} =
        Persistence.save_message(%{
          session_id: session_id,
          role: :user,
          content: "Previous message"
        })

      # Start session - should load existing
      {:ok, pid} =
        Manager.start_session(
          session_id: session_id,
          model: "anthropic:claude-sonnet-4-6",
          project_path: @project_path
        )

      # History should contain the previous message
      {:ok, history} = Session.get_history(pid)
      assert length(history) == 1
      assert hd(history).content == "Previous message"
    end

    test "get_status returns :idle initially" do
      session_id = Ecto.UUID.generate()

      {:ok, pid} =
        Manager.start_session(
          session_id: session_id,
          model: "test:model",
          project_path: @project_path
        )

      assert {:ok, :idle} = Session.get_status(pid)
    end

    test "can stop a session" do
      session_id = Ecto.UUID.generate()

      {:ok, pid} =
        Manager.start_session(
          session_id: session_id,
          model: "test:model",
          project_path: @project_path
        )

      assert Process.alive?(pid)
      assert :ok = Manager.stop_session(session_id)

      # Give it a moment to stop
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "list_active/0" do
    test "lists running sessions" do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      {:ok, _} =
        Manager.start_session(session_id: id1, model: "m", project_path: @project_path)

      {:ok, _} =
        Manager.start_session(session_id: id2, model: "m", project_path: @project_path)

      active = Manager.list_active()
      ids = Enum.map(active, & &1.id)
      assert id1 in ids
      assert id2 in ids
    end
  end

  describe "send_message/2 error handling" do
    test "returns error when LLM call fails (no API key)" do
      session_id = Ecto.UUID.generate()

      {:ok, pid} =
        Manager.start_session(
          session_id: session_id,
          model: "anthropic:claude-sonnet-4-6",
          project_path: @project_path
        )

      # This will fail because there's no API key configured
      result = Session.send_message(pid, "Hello")
      assert {:error, _reason} = result

      # But the user message should still have been saved
      messages = Persistence.load_messages(session_id)
      assert length(messages) == 1
      assert hd(messages).role == :user
      assert hd(messages).content == "Hello"
    end

    test "returns error for unknown session id" do
      assert {:error, :not_found} = Session.send_message(Ecto.UUID.generate(), "Hello")
    end
  end

  describe "get_history/1 and get_status/1 via session_id" do
    test "works with session_id string" do
      session_id = Ecto.UUID.generate()

      {:ok, _pid} =
        Manager.start_session(
          session_id: session_id,
          model: "m",
          project_path: @project_path
        )

      assert {:ok, []} = Session.get_history(session_id)
      assert {:ok, :idle} = Session.get_status(session_id)
    end

    test "returns error for unknown session" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Session.get_history(fake_id)
      assert {:error, :not_found} = Session.get_status(fake_id)
    end
  end
end
