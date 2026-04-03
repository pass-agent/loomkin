defmodule Loomkin.Teams.KeeperRehydrationTest do
  @moduledoc """
  Tests that context keeper rehydration is decoupled from WorkspaceServer
  and driven by Manager.ensure_nervous_system/1.
  """

  use Loomkin.DataCase, async: false

  alias Loomkin.Repo
  alias Loomkin.Schemas.ContextKeeper, as: KeeperSchema
  alias Loomkin.Teams.ContextKeeper
  alias Loomkin.Teams.Manager

  setup do
    on_exit(fn ->
      if Process.whereis(Loomkin.Teams.AgentSupervisor) do
        DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
        |> Enum.each(fn {_, pid, _, _} ->
          DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
        end)
      end
    end)

    :ok
  end

  describe "ensure_nervous_system/1 rehydrates keepers" do
    test "starts keepers from DB without WorkspaceServer" do
      {:ok, team_id} = Manager.create_team(name: "rehydrate-test")

      # Insert a keeper record directly into the DB
      keeper_id = Ecto.UUID.generate()

      %KeeperSchema{id: keeper_id}
      |> KeeperSchema.changeset(%{
        team_id: team_id,
        topic: "test-topic",
        source_agent: "coder",
        token_count: 42,
        status: :active,
        messages: %{"messages" => [%{"role" => "user", "content" => "hello"}]}
      })
      |> Repo.insert!()

      # Keepers should not be running yet (create_team doesn't rehydrate)
      assert Registry.lookup(Loomkin.Keepers.Registry, {team_id, keeper_id}) == []

      # ensure_nervous_system should start the keeper
      Manager.ensure_nervous_system(team_id)

      # Give the keeper a moment to start
      Process.sleep(50)

      assert [{pid, meta}] =
               Registry.lookup(Loomkin.Keepers.Registry, {team_id, keeper_id})

      assert Process.alive?(pid)
      assert meta.type == :keeper
      assert meta.topic == "test-topic"

      # Verify keeper loaded data from DB
      {:ok, messages} = ContextKeeper.retrieve_all(pid)
      assert length(messages) == 1
      assert hd(messages)["content"] == "hello"
    end

    test "is idempotent — does not double-start keepers" do
      {:ok, team_id} = Manager.create_team(name: "idempotent-rehydrate")

      keeper_id = Ecto.UUID.generate()

      %KeeperSchema{id: keeper_id}
      |> KeeperSchema.changeset(%{
        team_id: team_id,
        topic: "idem-topic",
        source_agent: "lead",
        token_count: 10,
        status: :active,
        messages: %{"messages" => []}
      })
      |> Repo.insert!()

      # Call twice
      Manager.ensure_nervous_system(team_id)
      Process.sleep(50)

      [{pid1, _}] =
        Registry.lookup(Loomkin.Keepers.Registry, {team_id, keeper_id})

      Manager.ensure_nervous_system(team_id)
      Process.sleep(50)

      [{pid2, _}] =
        Registry.lookup(Loomkin.Keepers.Registry, {team_id, keeper_id})

      # Same process — not restarted
      assert pid1 == pid2
      assert Process.alive?(pid1)
    end

    test "skips archived keepers" do
      {:ok, team_id} = Manager.create_team(name: "archived-keeper-test")

      keeper_id = Ecto.UUID.generate()

      %KeeperSchema{id: keeper_id}
      |> KeeperSchema.changeset(%{
        team_id: team_id,
        topic: "archived-topic",
        source_agent: "coder",
        token_count: 10,
        status: :archived,
        messages: %{"messages" => []}
      })
      |> Repo.insert!()

      Manager.ensure_nervous_system(team_id)
      Process.sleep(50)

      # Archived keeper should not be started
      assert Registry.lookup(Loomkin.Keepers.Registry, {team_id, keeper_id}) == []
    end

    test "rehydrates multiple keepers for the same team" do
      {:ok, team_id} = Manager.create_team(name: "multi-keeper-rehydrate")

      keeper_ids =
        for i <- 1..3 do
          id = Ecto.UUID.generate()

          %KeeperSchema{id: id}
          |> KeeperSchema.changeset(%{
            team_id: team_id,
            topic: "topic-#{i}",
            source_agent: "agent-#{i}",
            token_count: i * 10,
            status: :active,
            messages: %{"messages" => [%{"role" => "user", "content" => "msg-#{i}"}]}
          })
          |> Repo.insert!()

          id
        end

      Manager.ensure_nervous_system(team_id)
      Process.sleep(100)

      for keeper_id <- keeper_ids do
        assert [{pid, _}] =
                 Registry.lookup(Loomkin.Keepers.Registry, {team_id, keeper_id})

        assert Process.alive?(pid)
      end
    end
  end

  describe "ensure_team_table/1 rehydrates keepers on recovery" do
    test "keepers start when team table is recovered from workspace DB" do
      # Create a workspace with a team_id so recover_team_table can find it
      {:ok, workspace} =
        %Loomkin.Workspace{}
        |> Loomkin.Workspace.changeset(%{
          name: "recovery-ws",
          project_paths: ["/tmp/recovery-test"],
          status: :active
        })
        |> Repo.insert()

      {:ok, team_id} = Manager.create_team(name: "recovery-team")

      # Associate workspace with team
      import Ecto.Query

      Loomkin.Workspace
      |> where([w], w.id == ^workspace.id)
      |> Repo.update_all(set: [team_id: team_id])

      # Insert a keeper for this team
      keeper_id = Ecto.UUID.generate()

      %KeeperSchema{id: keeper_id}
      |> KeeperSchema.changeset(%{
        team_id: team_id,
        topic: "recovery-topic",
        source_agent: "researcher",
        token_count: 5,
        status: :active,
        messages: %{"messages" => [%{"role" => "user", "content" => "recovered"}]}
      })
      |> Repo.insert!()

      # Destroy the ETS table to simulate app restart
      Loomkin.Teams.TableRegistry.delete_table(team_id)

      # ensure_team_table should recover the table AND start keepers
      assert {:ok, _meta} = Manager.ensure_team_table(team_id)

      Process.sleep(100)

      assert [{pid, meta}] =
               Registry.lookup(Loomkin.Keepers.Registry, {team_id, keeper_id})

      assert Process.alive?(pid)
      assert meta.type == :keeper

      {:ok, messages} = ContextKeeper.retrieve_all(pid)
      assert length(messages) == 1
      assert hd(messages)["content"] == "recovered"
    end
  end
end
