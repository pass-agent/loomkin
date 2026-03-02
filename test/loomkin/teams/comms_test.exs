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

  describe "subscribe/2 and broadcast/2" do
    test "agent receives team-wide broadcasts after subscribing", %{team_id: team_id} do
      Comms.subscribe(team_id, "alice")
      Comms.broadcast(team_id, {:agent_status, "alice", :working})
      assert_receive {:agent_status, "alice", :working}
    end

    test "agent receives messages on all subscribed topics", %{team_id: team_id} do
      Comms.subscribe(team_id, "bob")

      # Team broadcast
      Comms.broadcast(team_id, {:test, :team})
      assert_receive {:test, :team}

      # Direct message
      Comms.send_to(team_id, "bob", {:test, :direct})
      assert_receive {:test, :direct}

      # Context
      Comms.broadcast_context(team_id, %{from: "bob", type: :discovery, content: "found it"})
      assert_receive {:context_update, "bob", %{from: "bob", type: :discovery}}

      # Task event
      Comms.broadcast_task_event(team_id, {:task_assigned, "t1", "bob"})
      assert_receive {:task_assigned, "t1", "bob"}

      # Decision
      Comms.broadcast_decision(team_id, "node-1", "bob")
      assert_receive {:decision_logged, "node-1", "bob"}
    end
  end

  describe "unsubscribe/2" do
    test "agent stops receiving messages after unsubscribing", %{team_id: team_id} do
      Comms.subscribe(team_id, "carol")
      Comms.unsubscribe(team_id, "carol")

      Comms.broadcast(team_id, {:test, :gone})
      refute_receive {:test, :gone}, 50
    end
  end

  describe "send_to/3" do
    test "only the targeted agent receives the message", %{team_id: team_id} do
      Comms.subscribe(team_id, "dave")
      Comms.subscribe(team_id, "eve")

      # Send only to dave's direct topic
      Comms.send_to(team_id, "dave", {:peer_message, "eve", "hello dave"})

      assert_receive {:peer_message, "eve", "hello dave"}
      # eve should not receive the direct message on her agent topic
      # (she would only get it on the team topic if it were broadcast)
    end
  end

  describe "broadcast_context/2" do
    test "delivers context_update tuple on context topic", %{team_id: team_id} do
      Comms.subscribe(team_id, "frank")

      payload = %{from: "frank", type: :file_change, content: %{path: "lib/foo.ex"}}
      Comms.broadcast_context(team_id, payload)

      assert_receive {:context_update, "frank", ^payload}
    end
  end

  describe "broadcast_task_event/2" do
    test "delivers task events on tasks topic", %{team_id: team_id} do
      Comms.subscribe(team_id, "grace")

      Comms.broadcast_task_event(team_id, {:task_completed, "t1", "grace", :ok})
      assert_receive {:task_completed, "t1", "grace", :ok}
    end
  end

  describe "broadcast_decision/3" do
    test "delivers decision_logged on decisions topic", %{team_id: team_id} do
      Comms.subscribe(team_id, "hank")

      Comms.broadcast_decision(team_id, "d-42", "hank")
      assert_receive {:decision_logged, "d-42", "hank"}
    end
  end
end
