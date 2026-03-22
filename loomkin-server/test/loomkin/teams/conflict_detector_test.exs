defmodule Loomkin.Teams.ConflictDetectorTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{ConflictDetector, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "conflict-test")

    # Ensure ConflictDetector is running (may not start in test env)
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:conflict_detector, team_id}) do
      [{_pid, _}] -> :ok
      [] -> ConflictDetector.start_link(team_id: team_id)
    end

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp tool_executing_signal(agent_name, team_id, tool_name, tool_target) do
    sig = Loomkin.Signals.Agent.ToolExecuting.new!(%{agent_name: agent_name, team_id: team_id})

    %{
      sig
      | data: Map.merge(sig.data, %{payload: %{tool_name: tool_name, tool_target: tool_target}})
    }
  end

  describe "extract_intent/1" do
    test "detects add intent" do
      assert ConflictDetector.extract_intent("Add a new module for authentication") == "add"
      assert ConflictDetector.extract_intent("Create a helper function") == "add"
      assert ConflictDetector.extract_intent("Implement the caching layer") == "add"
    end

    test "detects remove intent" do
      assert ConflictDetector.extract_intent("Remove the deprecated helper") == "remove"
      assert ConflictDetector.extract_intent("Delete unused imports") == "remove"
    end

    test "detects change intent" do
      assert ConflictDetector.extract_intent("Refactor the auth module") == "change"
      assert ConflictDetector.extract_intent("Rename function to match convention") == "change"
      assert ConflictDetector.extract_intent("Update the configuration") == "change"
    end

    test "returns unknown for ambiguous descriptions" do
      assert ConflictDetector.extract_intent("Look at the code") == "unknown"
    end
  end

  describe "extract_targets/1" do
    test "extracts file paths" do
      targets =
        ConflictDetector.extract_targets(
          "Edit lib/loomkin/teams/agent.ex and test/teams_test.exs"
        )

      assert MapSet.member?(targets, "lib/loomkin/teams/agent.ex")
      assert MapSet.member?(targets, "test/teams_test.exs")
    end

    test "extracts module names" do
      targets =
        ConflictDetector.extract_targets("Modify Loomkin.Teams.Agent to support new feature")

      assert MapSet.member?(targets, "Loomkin.Teams.Agent")
    end

    test "returns empty set for no identifiable targets" do
      targets = ConflictDetector.extract_targets("Do something general")
      assert MapSet.size(targets) == 0
    end
  end

  describe "check_approach_conflict/4" do
    test "detects conflict when agents add and remove from same file" do
      desc_a = "Add new validation to lib/loomkin/teams/agent.ex"
      desc_b = "Remove deprecated code from lib/loomkin/teams/agent.ex"

      result = ConflictDetector.check_approach_conflict(desc_a, desc_b, "coder-1", "coder-2")
      assert result != nil
      assert result =~ "coder-1"
      assert result =~ "coder-2"
    end

    test "no conflict when different files" do
      desc_a = "Add validation to lib/loomkin/teams/agent.ex"
      desc_b = "Remove code from lib/loomkin/teams/comms.ex"

      result = ConflictDetector.check_approach_conflict(desc_a, desc_b)
      assert result == nil
    end

    test "no conflict when same intent on same target" do
      desc_a = "Add helper to lib/loomkin/teams/agent.ex"
      desc_b = "Add tests for lib/loomkin/teams/agent.ex"

      result = ConflictDetector.check_approach_conflict(desc_a, desc_b)
      assert result == nil
    end

    test "detects conflict with module references" do
      desc_a = "Add new functions to Loomkin.Teams.Agent"
      desc_b = "Remove deprecated functions from Loomkin.Teams.Agent"

      result = ConflictDetector.check_approach_conflict(desc_a, desc_b, "alice", "bob")
      assert result != nil
      assert result =~ "alice"
      assert result =~ "bob"
    end
  end

  describe "GenServer file conflict detection" do
    test "detects when two agents edit the same file", %{team_id: team_id} do
      Loomkin.Signals.subscribe("collaboration.**")

      pid = find_conflict_detector(team_id)

      send(pid, {:signal, tool_executing_signal("coder-1", team_id, "file_edit", "lib/foo.ex")})
      send(pid, {:signal, tool_executing_signal("coder-2", team_id, "file_edit", "lib/foo.ex")})

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{
                          message:
                            {:conflict_detected, %{type: :file_conflict, description: desc}}
                        }
                      }},
                     1_000

      assert desc =~ "lib/foo.ex"
    end

    test "no conflict when same agent edits same file twice", %{team_id: team_id} do
      Loomkin.Signals.subscribe("collaboration.**")

      pid = find_conflict_detector(team_id)

      send(pid, {:signal, tool_executing_signal("coder-1", team_id, "file_edit", "lib/foo.ex")})
      send(pid, {:signal, tool_executing_signal("coder-1", team_id, "file_edit", "lib/foo.ex")})

      refute_receive {:signal, %Jido.Signal{data: %{message: {:conflict_detected, _}}}}, 200
    end

    test "no conflict when agents edit different files", %{team_id: team_id} do
      Loomkin.Signals.subscribe("collaboration.**")

      pid = find_conflict_detector(team_id)

      send(pid, {:signal, tool_executing_signal("coder-1", team_id, "file_edit", "lib/foo.ex")})
      send(pid, {:signal, tool_executing_signal("coder-2", team_id, "file_edit", "lib/bar.ex")})

      refute_receive {:signal, %Jido.Signal{data: %{message: {:conflict_detected, _}}}}, 200
    end
  end

  describe "GenServer decision conflict detection" do
    test "detects contradictory decisions on same topic", %{team_id: team_id} do
      Loomkin.Signals.subscribe("collaboration.**")

      {:ok, _node_a} =
        Loomkin.Decisions.Graph.add_node(%{
          node_type: :decision,
          title: "Use PostgreSQL for data storage layer",
          description: "We should use PostgreSQL",
          agent_name: "coder-1",
          metadata: %{"team_id" => team_id, "chosen" => "postgresql"}
        })

      {:ok, node_b} =
        Loomkin.Decisions.Graph.add_node(%{
          node_type: :decision,
          title: "Use MongoDB for data storage layer",
          description: "We should use MongoDB",
          agent_name: "coder-2",
          metadata: %{"team_id" => team_id, "chosen" => "mongodb"}
        })

      # Send a decision.logged signal to trigger conflict check
      pid = find_conflict_detector(team_id)

      sig =
        Loomkin.Signals.Decision.DecisionLogged.new!(%{
          node_id: node_b.id,
          agent_name: "coder-2",
          team_id: team_id
        })

      send(pid, {:signal, sig})

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{
                          message:
                            {:conflict_detected, %{type: :decision_conflict, description: desc}}
                        }
                      }},
                     1_000

      assert desc =~ "Contradictory decisions"
    end
  end

  defp find_conflict_detector(team_id) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:conflict_detector, team_id}) do
      [{pid, _}] -> pid
      [] -> raise "ConflictDetector not found for team #{team_id}"
    end
  end
end
