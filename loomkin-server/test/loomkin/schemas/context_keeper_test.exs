defmodule Loomkin.Schemas.ContextKeeperTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Schemas.ContextKeeper

  describe "changeset/2" do
    test "valid with all required fields" do
      attrs = %{
        team_id: "team-abc",
        topic: "file exploration",
        source_agent: "researcher",
        token_count: 500,
        status: :active
      }

      changeset = ContextKeeper.changeset(%ContextKeeper{}, attrs)
      assert changeset.valid?
    end

    test "valid with optional fields" do
      attrs = %{
        team_id: "team-abc",
        topic: "code review",
        source_agent: "coder",
        token_count: 1200,
        status: :active,
        messages: %{"messages" => [%{role: "user", content: "hello"}]},
        metadata: %{"tags" => ["elixir", "genserver"]}
      }

      changeset = ContextKeeper.changeset(%ContextKeeper{}, attrs)
      assert changeset.valid?
    end

    test "invalid without team_id" do
      attrs = %{topic: "test", source_agent: "agent", token_count: 0, status: :active}
      changeset = ContextKeeper.changeset(%ContextKeeper{}, attrs)
      refute changeset.valid?
      assert %{team_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without topic" do
      attrs = %{team_id: "team-1", source_agent: "agent", token_count: 0, status: :active}
      changeset = ContextKeeper.changeset(%ContextKeeper{}, attrs)
      refute changeset.valid?
      assert %{topic: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without source_agent" do
      attrs = %{team_id: "team-1", topic: "test", token_count: 0, status: :active}
      changeset = ContextKeeper.changeset(%ContextKeeper{}, attrs)
      refute changeset.valid?
      assert %{source_agent: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without token_count" do
      attrs = %{team_id: "team-1", topic: "test", source_agent: "agent", status: :active}
      changeset = ContextKeeper.changeset(%ContextKeeper{}, attrs)
      refute changeset.valid?
      assert %{token_count: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without status" do
      attrs = %{team_id: "team-1", topic: "test", source_agent: "agent", token_count: 0}
      changeset = ContextKeeper.changeset(%ContextKeeper{}, attrs)
      refute changeset.valid?
      assert %{status: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid status value" do
      attrs = %{
        team_id: "team-1",
        topic: "test",
        source_agent: "agent",
        token_count: 0,
        status: :invalid
      }

      changeset = ContextKeeper.changeset(%ContextKeeper{}, attrs)
      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "persists to database" do
      attrs = %{
        team_id: "team-persist",
        topic: "persistence test",
        source_agent: "tester",
        token_count: 42,
        status: :active,
        messages: %{"messages" => []},
        metadata: %{}
      }

      {:ok, keeper} =
        %ContextKeeper{}
        |> ContextKeeper.changeset(attrs)
        |> Repo.insert()

      assert keeper.id
      assert keeper.team_id == "team-persist"
      assert keeper.topic == "persistence test"
      assert keeper.inserted_at
    end
  end
end
