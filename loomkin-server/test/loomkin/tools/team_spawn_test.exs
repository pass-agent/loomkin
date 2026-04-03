defmodule Loomkin.Tools.TeamSpawnTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Manager
  alias Loomkin.Tools.TeamSpawn

  setup do
    # Subscribe to child team signals before each test
    Loomkin.Signals.subscribe("team.**")
    :ok
  end

  describe "ChildTeamCreated signal not published from tool" do
    test "TeamSpawn.run/2 does not publish ChildTeamCreated after migration" do
      # Create a parent team to spawn a sub-team under
      {:ok, parent_team_id} = Manager.create_team(name: "parent-for-spawn-test")

      params = %{
        team_name: "child-team-from-tool",
        roles: [%{name: "researcher-1", role: "researcher"}],
        purpose: "test signal deduplication"
      }

      context = %{
        parent_team_id: parent_team_id,
        project_path: nil,
        session_id: nil,
        model: nil,
        agent_name: "test-agent"
      }

      # Drain any signals that may already be in the mailbox
      flush_signals()

      # Call TeamSpawn.run/2 directly — the tool should NOT publish ChildTeamCreated
      {:ok, _result} = TeamSpawn.run(params, context)

      # The Manager.create_sub_team/3 WILL publish ChildTeamCreated — we want exactly one.
      # The tool itself should not publish a second copy.
      # Wait a short time for any signals to arrive
      signals = collect_child_created_signals(100)

      # Should be exactly 1 (from Manager), NOT 2 (tool duplicate)
      assert length(signals) == 1,
             "Expected exactly 1 ChildTeamCreated signal, got #{length(signals)}"

      on_exit(fn ->
        Manager.dissolve_team(parent_team_id)
      end)
    end

    test "ChildTeamCreated is published exactly once by Manager.create_sub_team/3" do
      {:ok, parent_team_id} = Manager.create_team(name: "parent-for-manager-test")

      # Drain mailbox before subscribing
      flush_signals()

      {:ok, sub_team_id} =
        Manager.create_sub_team(parent_team_id, "lead-agent", name: "child-team")

      # Should receive the signal with team_name and depth
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.child.created",
                        data: %{
                          team_id: ^sub_team_id,
                          parent_team_id: ^parent_team_id,
                          team_name: "child-team",
                          depth: 1
                        }
                      }},
                     500

      # Should not receive a second copy
      refute_receive {:signal, %Jido.Signal{type: "team.child.created"}}, 100

      on_exit(fn ->
        Manager.dissolve_team(parent_team_id)
      end)
    end
  end

  describe "role resolution" do
    test "resolve_role maps 'coordinator' to lead via fuzzy match" do
      {:ok, parent_team_id} = Manager.create_team(name: "role-res-coord")

      params = %{
        team_name: "coord-role-test",
        roles: [%{name: "c1", role: "coordinator"}],
        purpose: "test coordinator resolution"
      }

      context = %{
        parent_team_id: parent_team_id,
        project_path: nil,
        session_id: nil,
        model: nil,
        agent_name: "test-agent"
      }

      {:ok, result} = TeamSpawn.run(params, context)
      assert result.result =~ "c1 (lead): spawned"

      on_exit(fn -> Manager.dissolve_team(parent_team_id) end)
    end
  end

  describe "team manifest" do
    test "spawning agents sends peer_message briefing to each" do
      {:ok, parent_team_id} = Manager.create_team(name: "manifest-parent")

      params = %{
        team_name: "manifest-test",
        roles: [
          %{name: "r1", role: "researcher"},
          %{name: "c1", role: "coder"},
          %{name: "w1", role: "reviewer"}
        ],
        purpose: "test manifest delivery"
      }

      context = %{
        parent_team_id: parent_team_id,
        project_path: nil,
        session_id: nil,
        model: nil,
        agent_name: "test-agent"
      }

      {:ok, result} = TeamSpawn.run(params, context)
      team_id = result.team_id

      # Give peer_messages time to be delivered (they are casts)
      Process.sleep(200)

      # Check each agent received a manifest via peer_message in their messages
      for agent_name <- ["r1", "c1", "w1"] do
        {:ok, pid} = Manager.find_agent(team_id, agent_name)
        state = :sys.get_state(pid)

        manifest_msgs =
          Enum.filter(state.messages, fn msg ->
            msg.role == :user and String.contains?(msg.content, "[Team Briefing]")
          end)

        assert length(manifest_msgs) >= 1,
               "Expected #{agent_name} to receive a team manifest peer_message"
      end

      on_exit(fn -> Manager.dissolve_team(parent_team_id) end)
    end

    test "manifest includes sibling names and roles but excludes self" do
      {:ok, parent_team_id} = Manager.create_team(name: "manifest-excl-parent")

      params = %{
        team_name: "manifest-exclusion-test",
        roles: [
          %{name: "alice", role: "researcher"},
          %{name: "bob", role: "coder"}
        ],
        purpose: "test manifest exclusion"
      }

      context = %{
        parent_team_id: parent_team_id,
        project_path: nil,
        session_id: nil,
        model: nil,
        agent_name: "test-agent"
      }

      {:ok, result} = TeamSpawn.run(params, context)
      team_id = result.team_id

      Process.sleep(200)

      # Check alice's manifest includes bob but not herself
      {:ok, alice_pid} = Manager.find_agent(team_id, "alice")
      alice_state = :sys.get_state(alice_pid)

      alice_manifest =
        Enum.find(alice_state.messages, fn msg ->
          msg.role == :user and String.contains?(msg.content, "[Team Briefing]")
        end)

      assert alice_manifest.content =~ "bob"
      assert alice_manifest.content =~ "coder"
      # The manifest should say "You are alice" but not list alice as a teammate
      assert alice_manifest.content =~ "You are alice"
      refute alice_manifest.content =~ "- **alice**"

      # Check bob's manifest includes alice but not himself
      {:ok, bob_pid} = Manager.find_agent(team_id, "bob")
      bob_state = :sys.get_state(bob_pid)

      bob_manifest =
        Enum.find(bob_state.messages, fn msg ->
          msg.role == :user and String.contains?(msg.content, "[Team Briefing]")
        end)

      assert bob_manifest.content =~ "alice"
      assert bob_manifest.content =~ "researcher"
      assert bob_manifest.content =~ "You are bob"
      refute bob_manifest.content =~ "- **bob**"

      on_exit(fn -> Manager.dissolve_team(parent_team_id) end)
    end
  end

  # Collect all team.child.created signals arriving within timeout_ms
  defp collect_child_created_signals(timeout_ms) do
    collect_signals("team.child.created", timeout_ms, [])
  end

  defp collect_signals(type, timeout_ms, acc) do
    receive do
      {:signal, %Jido.Signal{type: ^type} = signal} ->
        collect_signals(type, timeout_ms, [signal | acc])
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end

  defp flush_signals do
    receive do
      {:signal, _} -> flush_signals()
    after
      0 -> :ok
    end
  end
end
