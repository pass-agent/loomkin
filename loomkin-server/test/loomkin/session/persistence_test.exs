defmodule Loomkin.Session.PersistenceTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Session.Persistence

  describe "create_session/1" do
    test "creates a session with valid attrs" do
      attrs = %{model: "zai:glm-5", project_path: "/tmp/test"}

      assert {:ok, session} = Persistence.create_session(attrs)
      assert session.model == "zai:glm-5"
      assert session.project_path == "/tmp/test"
      assert session.status == :active
      assert session.prompt_tokens == 0
      assert session.completion_tokens == 0
    end

    test "fails without required fields" do
      assert {:error, changeset} = Persistence.create_session(%{})
      refute changeset.valid?
    end
  end

  describe "get_session/1" do
    test "returns session by id" do
      {:ok, session} =
        Persistence.create_session(%{model: "test:model", project_path: "/tmp"})

      assert found = Persistence.get_session(session.id)
      assert found.id == session.id
    end

    test "returns nil for unknown id" do
      assert Persistence.get_session(Ecto.UUID.generate()) == nil
    end
  end

  describe "list_sessions/1" do
    test "lists all sessions" do
      {:ok, _} = Persistence.create_session(%{model: "m1", project_path: "/a"})
      {:ok, _} = Persistence.create_session(%{model: "m2", project_path: "/b"})

      sessions = Persistence.list_sessions()
      assert length(sessions) == 2
    end

    test "filters by status" do
      {:ok, s1} = Persistence.create_session(%{model: "m", project_path: "/a"})
      {:ok, _} = Persistence.create_session(%{model: "m", project_path: "/b"})
      Persistence.archive_session(s1)

      active = Persistence.list_sessions(status: :active)
      assert length(active) == 1

      archived = Persistence.list_sessions(status: :archived)
      assert length(archived) == 1
    end

    test "filters by project_path" do
      {:ok, _} = Persistence.create_session(%{model: "m", project_path: "/proj/a"})
      {:ok, _} = Persistence.create_session(%{model: "m", project_path: "/proj/b"})

      results = Persistence.list_sessions(project_path: "/proj/a")
      assert length(results) == 1
      assert hd(results).project_path == "/proj/a"
    end
  end

  describe "update_session/2" do
    test "updates session fields" do
      {:ok, session} =
        Persistence.create_session(%{model: "m", project_path: "/tmp"})

      {:ok, updated} = Persistence.update_session(session, %{title: "New Title"})
      assert updated.title == "New Title"
    end
  end

  describe "archive_session/1" do
    test "sets status to archived" do
      {:ok, session} =
        Persistence.create_session(%{model: "m", project_path: "/tmp"})

      {:ok, archived} = Persistence.archive_session(session)
      assert archived.status == :archived
    end
  end

  describe "save_message/1 and load_messages/1" do
    test "saves and loads messages in order" do
      {:ok, session} =
        Persistence.create_session(%{model: "m", project_path: "/tmp"})

      {:ok, _} =
        Persistence.save_message(%{
          session_id: session.id,
          role: :user,
          content: "Hello"
        })

      {:ok, _} =
        Persistence.save_message(%{
          session_id: session.id,
          role: :assistant,
          content: "Hi there!"
        })

      messages = Persistence.load_messages(session.id)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == :user
      assert Enum.at(messages, 0).content == "Hello"
      assert Enum.at(messages, 1).role == :assistant
      assert Enum.at(messages, 1).content == "Hi there!"
    end
  end

  describe "update_costs/4" do
    test "increments token counts and cost atomically" do
      {:ok, session} =
        Persistence.create_session(%{model: "m", project_path: "/tmp"})

      assert :ok = Persistence.update_costs(session.id, 100, 50, 0.005)
      updated = Persistence.get_session(session.id)
      assert updated.prompt_tokens == 100
      assert updated.completion_tokens == 50
      assert Decimal.compare(updated.cost_usd, Decimal.new("0.005")) == :eq

      # Increment again
      assert :ok = Persistence.update_costs(session.id, 200, 100, 0.01)
      updated2 = Persistence.get_session(session.id)
      assert updated2.prompt_tokens == 300
      assert updated2.completion_tokens == 150
      assert Decimal.compare(updated2.cost_usd, Decimal.new("0.015")) == :eq
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} =
               Persistence.update_costs(Ecto.UUID.generate(), 10, 10, 0.001)
    end
  end
end
