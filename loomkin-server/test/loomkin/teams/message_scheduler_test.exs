defmodule Loomkin.Teams.MessageSchedulerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.MessageScheduler
  alias Loomkin.Teams.MessageScheduler.ScheduledMessage

  setup do
    # Use a unique team_id per test to avoid registry collisions
    team_id = "test-scheduler-#{:erlang.unique_integer([:positive])}"

    # Start the scheduler for our test team (uses the app-level AgentRegistry)
    start_supervised!({MessageScheduler, team_id: team_id})

    # Subscribe to PubSub for broadcast assertions
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")

    %{team_id: team_id}
  end

  describe "schedule/5" do
    test "creates a pending message with a timer", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, %ScheduledMessage{} = msg} =
               MessageScheduler.schedule(team_id, "hello agent", "coder", deliver_at)

      assert msg.content == "hello agent"
      assert msg.target_agent == "coder"
      assert msg.team_id == team_id
      assert msg.status == :pending
      assert msg.deliver_at == deliver_at
      assert msg.timer_ref != nil
    end

    test "rejects scheduling in the past", %{team_id: team_id} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:error, :in_the_past} =
               MessageScheduler.schedule(team_id, "too late", "coder", past)
    end

    test "broadcasts schedule_updated on creation", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 60, :second)
      {:ok, _msg} = MessageScheduler.schedule(team_id, "content", "coder", deliver_at)

      assert_receive {:schedule_updated, ^team_id, pending_list}
      assert length(pending_list) == 1
      assert hd(pending_list).content == "content"
    end
  end

  describe "cancel/2" do
    test "cancels a pending message and updates status", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 60, :second)
      {:ok, msg} = MessageScheduler.schedule(team_id, "cancel me", "coder", deliver_at)

      # Drain the schedule broadcast
      assert_receive {:schedule_updated, _, _}

      assert :ok = MessageScheduler.cancel(team_id, msg.id)

      # Verify it's cancelled via list
      all = MessageScheduler.list(team_id, status: :all)
      cancelled = Enum.find(all, &(&1.id == msg.id))
      assert cancelled.status == :cancelled
    end

    test "returns error for unknown message id", %{team_id: team_id} do
      assert {:error, :not_found} = MessageScheduler.cancel(team_id, "nonexistent")
    end

    test "broadcasts schedule_updated on cancel", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 60, :second)
      {:ok, msg} = MessageScheduler.schedule(team_id, "cancel me", "coder", deliver_at)
      assert_receive {:schedule_updated, _, _}

      MessageScheduler.cancel(team_id, msg.id)

      assert_receive {:schedule_updated, ^team_id, pending_list}
      assert pending_list == []
    end
  end

  describe "edit/3" do
    test "updates content without changing timer", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 60, :second)
      {:ok, msg} = MessageScheduler.schedule(team_id, "original", "coder", deliver_at)

      assert {:ok, updated} =
               MessageScheduler.edit(team_id, msg.id, %{content: "edited"})

      assert updated.content == "edited"
      assert updated.deliver_at == deliver_at
      assert updated.timer_ref != nil
    end

    test "updates deliver_at and resets timer", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 60, :second)
      {:ok, msg} = MessageScheduler.schedule(team_id, "content", "coder", deliver_at)

      new_deliver_at = DateTime.add(DateTime.utc_now(), 120, :second)

      assert {:ok, updated} =
               MessageScheduler.edit(team_id, msg.id, %{deliver_at: new_deliver_at})

      assert updated.deliver_at == new_deliver_at
      # Timer ref should be different (old cancelled, new created)
      assert updated.timer_ref != msg.timer_ref
    end

    test "rejects editing deliver_at to the past", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 60, :second)
      {:ok, msg} = MessageScheduler.schedule(team_id, "content", "coder", deliver_at)

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:error, :in_the_past} =
               MessageScheduler.edit(team_id, msg.id, %{deliver_at: past})
    end

    test "returns error for unknown message id", %{team_id: team_id} do
      assert {:error, :not_found} =
               MessageScheduler.edit(team_id, "nonexistent", %{content: "x"})
    end
  end

  describe "list/2" do
    test "returns only pending messages by default, sorted by deliver_at", %{team_id: team_id} do
      t1 = DateTime.add(DateTime.utc_now(), 120, :second)
      t2 = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, _msg1} = MessageScheduler.schedule(team_id, "later", "coder", t1)
      {:ok, _msg2} = MessageScheduler.schedule(team_id, "sooner", "coder", t2)

      pending = MessageScheduler.list(team_id)
      assert length(pending) == 2
      # Sooner should be first
      assert hd(pending).content == "sooner"
    end

    test "returns all messages with status: :all", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 60, :second)
      {:ok, msg} = MessageScheduler.schedule(team_id, "will cancel", "coder", deliver_at)
      {:ok, _msg2} = MessageScheduler.schedule(team_id, "keep", "coder", deliver_at)

      MessageScheduler.cancel(team_id, msg.id)

      all = MessageScheduler.list(team_id, status: :all)
      assert length(all) == 2

      pending = MessageScheduler.list(team_id)
      assert length(pending) == 1
      assert hd(pending).content == "keep"
    end
  end

  describe "time_remaining/2" do
    test "returns remaining seconds", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 120, :second)
      {:ok, msg} = MessageScheduler.schedule(team_id, "content", "coder", deliver_at)

      assert {:ok, seconds} = MessageScheduler.time_remaining(team_id, msg.id)
      # Should be roughly 120 seconds (allow some margin)
      assert seconds >= 118 and seconds <= 121
    end

    test "returns error for unknown message", %{team_id: team_id} do
      assert {:error, :not_found} = MessageScheduler.time_remaining(team_id, "nope")
    end
  end

  describe "delivery" do
    test "delivers message to agent and broadcasts", %{team_id: team_id} do
      # Start a fake agent that registers itself in the AgentRegistry
      test_pid = self()

      _fake_pid =
        start_supervised!(
          {Loomkin.Teams.FakeAgent,
           team_id: team_id, agent_name: "test-agent", test_pid: test_pid}
        )

      # Schedule delivery 50ms from now
      deliver_at = DateTime.add(DateTime.utc_now(), 50, :millisecond)

      {:ok, msg} =
        MessageScheduler.schedule(team_id, "delayed hello", "test-agent", deliver_at)

      # Wait for delivery
      assert_receive {:scheduled_delivered, msg_id, "test-agent"}, 2000
      assert msg_id == msg.id

      # Verify message was sent to the fake agent
      assert_receive {:message_received, "delayed hello"}, 1000

      # Verify status updated
      all = MessageScheduler.list(team_id, status: :all)
      delivered = Enum.find(all, &(&1.id == msg.id))
      assert delivered.status == :delivered
    end

    test "marks as failed when agent not found", %{team_id: team_id} do
      deliver_at = DateTime.add(DateTime.utc_now(), 50, :millisecond)

      {:ok, msg} =
        MessageScheduler.schedule(team_id, "no agent", "ghost-agent", deliver_at)

      # Drain the schedule_updated from the initial schedule call
      assert_receive {:schedule_updated, ^team_id, _}, 1000

      # Wait for the schedule_updated from the failed delivery attempt
      assert_receive {:schedule_updated, ^team_id, _}, 2000

      # Check that it's failed
      all = MessageScheduler.list(team_id, status: :all)
      failed = Enum.find(all, &(&1.id == msg.id))
      assert failed.status == :failed
    end
  end
end

defmodule Loomkin.Teams.FakeAgent do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    agent_name = Keyword.fetch!(opts, :agent_name)
    test_pid = Keyword.fetch!(opts, :test_pid)

    # Register this process as the agent in the AgentRegistry
    Registry.register(Loomkin.Teams.AgentRegistry, {team_id, agent_name}, %{})

    {:ok, %{test_pid: test_pid}}
  end

  def handle_call({:send_message, text}, _from, state) do
    send(state.test_pid, {:message_received, text})
    {:reply, :ok, state}
  end
end
