defmodule Loomkin.Decisions.AutoLoggerTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.{AutoLogger, Graph}
  alias Loomkin.Teams.Comms

  setup do
    team_id = Ecto.UUID.generate()

    # Create ETS table for team (AutoLogger uses Registry, not ETS directly, but
    # task lookups may need it)
    {:ok, _ref} = Loomkin.Teams.TableRegistry.create_table(team_id)

    {:ok, _pid} = start_supervised({AutoLogger, team_id: team_id})

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "agent_status events" do
    test "logs action node on first :working status", %{team_id: team_id} do
      Comms.broadcast(team_id, {:agent_status, "alice", :working})
      Process.sleep(50)

      nodes = Graph.list_nodes(node_type: :action)
      assert length(nodes) == 1
      assert hd(nodes).title == "Agent alice joined team"
      assert hd(nodes).metadata["auto_logged"] == true
      assert hd(nodes).metadata["team_id"] == team_id
    end

    test "only logs once per agent (deduplicates)", %{team_id: team_id} do
      Comms.broadcast(team_id, {:agent_status, "bob", :working})
      Process.sleep(50)
      Comms.broadcast(team_id, {:agent_status, "bob", :working})
      Process.sleep(50)

      nodes = Graph.list_nodes(node_type: :action)
      assert length(nodes) == 1
    end

    test "logs separate nodes for different agents", %{team_id: team_id} do
      Comms.broadcast(team_id, {:agent_status, "alice", :working})
      Comms.broadcast(team_id, {:agent_status, "bob", :working})
      Process.sleep(50)

      nodes = Graph.list_nodes(node_type: :action)
      assert length(nodes) == 2
      titles = Enum.map(nodes, & &1.title)
      assert "Agent alice joined team" in titles
      assert "Agent bob joined team" in titles
    end

    test "ignores non-working statuses", %{team_id: team_id} do
      Comms.broadcast(team_id, {:agent_status, "carol", :idle})
      Process.sleep(50)

      assert Graph.list_nodes(node_type: :action) == []
    end
  end

  describe "task events" do
    test "task_assigned creates action node", %{team_id: team_id} do
      # Create a task in the DB so the title can be looked up
      {:ok, task} = create_task(team_id, "Implement feature X")

      Comms.broadcast_task_event(team_id, {:task_assigned, task.id, "alice"})
      Process.sleep(50)

      nodes = Graph.list_nodes(node_type: :action)
      assert length(nodes) == 1
      node = hd(nodes)
      assert node.title =~ "Task assigned: Implement feature X"
      assert node.title =~ "alice"
      assert node.metadata["auto_logged"] == true
    end

    test "task_completed creates outcome node with edge from task action", %{team_id: team_id} do
      {:ok, task} = create_task(team_id, "Fix bug Y")

      # First assign (creates action node)
      Comms.broadcast_task_event(team_id, {:task_assigned, task.id, "bob"})
      Process.sleep(50)

      # Then complete (creates outcome node + edge)
      Comms.broadcast_task_event(team_id, {:task_completed, task.id, "bob", "done"})
      Process.sleep(50)

      outcomes = Graph.list_nodes(node_type: :outcome)
      assert length(outcomes) == 1
      outcome = hd(outcomes)
      assert outcome.title == "Completed: Fix bug Y"

      # Verify edge from action → outcome
      edges = Graph.list_edges(edge_type: :leads_to, to_node_id: outcome.id)
      assert length(edges) >= 1

      action = hd(Graph.list_nodes(node_type: :action))
      assert Enum.any?(edges, &(&1.from_node_id == action.id))
    end

    test "task_failed creates outcome node", %{team_id: team_id} do
      {:ok, task} = create_task(team_id, "Deploy service")

      Comms.broadcast_task_event(team_id, {:task_assigned, task.id, "carol"})
      Process.sleep(50)

      Comms.broadcast_task_event(team_id, {:task_failed, task.id, "carol", "timeout"})
      Process.sleep(50)

      outcomes = Graph.list_nodes(node_type: :outcome)
      assert length(outcomes) == 1
      outcome = hd(outcomes)
      assert outcome.title =~ "Failed: Deploy service"
      assert outcome.title =~ "timeout"
    end
  end

  describe "keeper_created events" do
    test "creates observation node with keeper_id in metadata", %{team_id: team_id} do
      keeper_id = Ecto.UUID.generate()

      Comms.broadcast(
        team_id,
        {:keeper_created,
         %{
           id: keeper_id,
           topic: "auth-research",
           source: "alice",
           tokens: 500
         }}
      )

      Process.sleep(50)

      nodes = Graph.list_nodes(node_type: :observation)
      assert length(nodes) == 1
      node = hd(nodes)
      assert node.title == "Context offloaded: auth-research"
      assert node.metadata["keeper_id"] == keeper_id
      assert node.metadata["auto_logged"] == true
    end
  end

  describe "context_offloaded events" do
    test "are skipped (redundant with keeper_created)", %{team_id: team_id} do
      Comms.broadcast(team_id, {:context_offloaded, "alice", %{some: "data"}})
      Process.sleep(50)

      assert Graph.list_nodes() == []
    end
  end

  describe "active goal linking" do
    test "edges action nodes to active goal when one exists", %{team_id: team_id} do
      # Create an active goal node with team_id so AutoLogger's scoped query finds it
      {:ok, goal} =
        Graph.add_node(%{
          node_type: :goal,
          title: "Ship v1",
          status: :active,
          metadata: %{"team_id" => team_id}
        })

      Comms.broadcast(team_id, {:agent_status, "alice", :working})
      Process.sleep(50)

      action = hd(Graph.list_nodes(node_type: :action))
      edges = Graph.list_edges(from_node_id: goal.id, edge_type: :leads_to)
      assert Enum.any?(edges, &(&1.to_node_id == action.id))
    end
  end

  # --- Helpers ---

  defp create_task(team_id, title) do
    %Loomkin.Schemas.TeamTask{}
    |> Loomkin.Schemas.TeamTask.changeset(%{team_id: team_id, title: title, status: :pending})
    |> Repo.insert()
  end
end
