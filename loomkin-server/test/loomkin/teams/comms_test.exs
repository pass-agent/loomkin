defmodule Loomkin.Teams.CommsTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Comms, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "comms-test")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "subscribe/2 subscription id tracking" do
    test "returns {:ok, subscription_ids} with non-empty list", %{team_id: team_id} do
      assert {:ok, sub_ids} = Comms.subscribe(team_id, "tracker")
      assert is_list(sub_ids)
      assert length(sub_ids) > 0
    end

    test "uses Topics module functions (no raw strings)", _context do
      source = File.read!("lib/loomkin/teams/comms.ex")
      # Should not contain raw glob patterns in subscribe calls
      refute source =~ ~r/Signals\.subscribe\("agent\.\*\*"\)/
      refute source =~ ~r/Signals\.subscribe\("team\.\*\*"\)/
      refute source =~ ~r/Signals\.subscribe\("context\.\*\*"\)/
      refute source =~ ~r/Signals\.subscribe\("collaboration\.\*\*"\)/
      refute source =~ ~r/Signals\.subscribe\("decision\.\*\*"\)/
    end
  end

  describe "unsubscribe/1 with subscription ids" do
    test "does not raise when unsubscribing valid ids", %{team_id: team_id} do
      {:ok, sub_ids} = Comms.subscribe(team_id, "unsub-test")
      assert :ok = Comms.unsubscribe(sub_ids)
    end
  end

  describe "subscribe/2 and broadcast/2" do
    test "agent receives team-wide broadcasts after subscribing", %{team_id: team_id} do
      {:ok, _sub_ids} = Comms.subscribe(team_id, "alice")
      Comms.broadcast(team_id, {:agent_status, "alice", :working})
      assert_receive {:signal, %Jido.Signal{type: "collaboration.peer.message"}}, 500
    end

    test "agent receives messages on all subscribed topics", %{team_id: team_id} do
      {:ok, _sub_ids} = Comms.subscribe(team_id, "bob")

      # Team broadcast
      Comms.broadcast(team_id, {:test, :team})
      assert_receive {:signal, %Jido.Signal{type: "collaboration.peer.message"}}, 500

      # Direct message
      Comms.send_to(team_id, "bob", {:test, :direct})
      assert_receive {:signal, %Jido.Signal{type: "collaboration.peer.message"}}, 500

      # Context
      Comms.broadcast_context(team_id, %{from: "bob", type: :discovery, content: "found it"})
      assert_receive {:signal, %Jido.Signal{type: "context.update"}}, 500

      # Task event
      Comms.broadcast_task_event(team_id, {:task_assigned, "t1", "bob"})
      assert_receive {:signal, %Jido.Signal{type: "team.task.assigned"}}, 500

      # Decision
      Comms.broadcast_decision(team_id, "node-1", "bob")
      assert_receive {:signal, %Jido.Signal{type: "decision.logged"}}, 500
    end
  end

  describe "send_to/3" do
    test "sends a direct message signal", %{team_id: team_id} do
      {:ok, _sub_ids} = Comms.subscribe(team_id, "dave")

      Comms.send_to(team_id, "dave", {:peer_message, "eve", "hello dave"})

      assert_receive {:signal, %Jido.Signal{type: "collaboration.peer.message"}}, 500
    end
  end

  describe "broadcast_context/2" do
    test "delivers context update signal", %{team_id: team_id} do
      {:ok, _sub_ids} = Comms.subscribe(team_id, "frank")

      payload = %{from: "frank", type: :file_change, content: %{path: "lib/foo.ex"}}
      Comms.broadcast_context(team_id, payload)

      assert_receive {:signal, %Jido.Signal{type: "context.update"}}, 500
    end
  end

  describe "broadcast_task_event/2" do
    test "delivers task event signals", %{team_id: team_id} do
      {:ok, _sub_ids} = Comms.subscribe(team_id, "grace")

      Comms.broadcast_task_event(team_id, {:task_completed, "t1", "grace", :ok})
      assert_receive {:signal, %Jido.Signal{type: "team.task.completed"}}, 500
    end
  end

  describe "broadcast_decision/3" do
    test "delivers decision signal", %{team_id: team_id} do
      {:ok, _sub_ids} = Comms.subscribe(team_id, "hank")

      Comms.broadcast_decision(team_id, "d-42", "hank")
      assert_receive {:signal, %Jido.Signal{type: "decision.logged"}}, 500
    end
  end
end
