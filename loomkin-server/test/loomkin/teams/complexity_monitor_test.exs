defmodule Loomkin.Teams.ComplexityMonitorTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.CollaborationMetrics
  alias Loomkin.Teams.ComplexityMonitor
  alias Loomkin.Teams.Context
  alias Loomkin.Teams.Manager

  setup do
    Application.put_env(:loomkin, :start_nervous_system, false)

    {:ok, team_id} = Manager.create_team(name: "complexity-test")

    on_exit(fn ->
      Application.put_env(:loomkin, :start_nervous_system, true)
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp start_monitor(team_id, opts \\ []) do
    opts = Keyword.merge([team_id: team_id, check_interval: 100_000], opts)
    {:ok, pid} = ComplexityMonitor.start_link(opts)
    Ecto.Adapters.SQL.Sandbox.allow(Loomkin.Repo, self(), pid)
    pid
  end

  # Seed pending tasks in ETS cache to boost the task_score component
  defp seed_pending_tasks(team_id, count) do
    for i <- 1..count do
      Context.cache_task(team_id, Ecto.UUID.generate(), %{
        title: "task-#{i}",
        status: :pending,
        owner: nil
      })
    end
  end

  describe "start_link/1" do
    test "starts and registers via AgentRegistry", %{team_id: team_id} do
      pid = start_monitor(team_id)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "get_score/1" do
    test "returns 0 when monitor is not running" do
      assert ComplexityMonitor.get_score("nonexistent") == 0
    end

    test "returns a score between 0 and 100", %{team_id: team_id} do
      pid = start_monitor(team_id)
      score = ComplexityMonitor.get_score(team_id)
      assert is_integer(score)
      assert score >= 0 and score <= 100
      GenServer.stop(pid)
    end
  end

  describe "get_trend/1" do
    test "returns :stable with no history", %{team_id: team_id} do
      pid = start_monitor(team_id)
      assert ComplexityMonitor.get_trend(team_id) == :stable
      GenServer.stop(pid)
    end

    test "returns :rising when score jumps", %{team_id: team_id} do
      pid = start_monitor(team_id)

      :sys.replace_state(pid, fn state ->
        %{state | scores: [50, 30, 25]}
      end)

      assert ComplexityMonitor.get_trend(team_id) == :rising
      GenServer.stop(pid)
    end

    test "returns :falling when score drops", %{team_id: team_id} do
      pid = start_monitor(team_id)

      :sys.replace_state(pid, fn state ->
        %{state | scores: [20, 50, 45]}
      end)

      assert ComplexityMonitor.get_trend(team_id) == :falling
      GenServer.stop(pid)
    end

    test "returns :stable when score changes are small", %{team_id: team_id} do
      pid = start_monitor(team_id)

      :sys.replace_state(pid, fn state ->
        %{state | scores: [40, 35, 38]}
      end)

      assert ComplexityMonitor.get_trend(team_id) == :stable
      GenServer.stop(pid)
    end
  end

  describe "get_history/1" do
    test "returns empty list initially", %{team_id: team_id} do
      pid = start_monitor(team_id)
      assert ComplexityMonitor.get_history(team_id) == []
      GenServer.stop(pid)
    end

    test "accumulates scores on check", %{team_id: team_id} do
      pid = start_monitor(team_id)

      send(pid, :check_complexity)
      _ = :sys.get_state(pid)

      history = ComplexityMonitor.get_history(team_id)
      assert length(history) == 1

      GenServer.stop(pid)
    end
  end

  describe "record_event/2" do
    test "increments conflict counter", %{team_id: team_id} do
      pid = start_monitor(team_id)

      ComplexityMonitor.record_event(team_id, :conflict)
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.pending_events.conflicts == 1

      GenServer.stop(pid)
    end

    test "increments debate counter", %{team_id: team_id} do
      pid = start_monitor(team_id)

      ComplexityMonitor.record_event(team_id, :debate)
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.pending_events.debates == 1

      GenServer.stop(pid)
    end

    test "increments task_created counter", %{team_id: team_id} do
      pid = start_monitor(team_id)

      ComplexityMonitor.record_event(team_id, :task_created)
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.pending_events.tasks_created == 1

      GenServer.stop(pid)
    end
  end

  describe "threshold trigger" do
    test "fires spawn suggestion when score spikes above threshold", %{team_id: team_id} do
      pid = start_monitor(team_id, threshold: 10)

      Loomkin.Signals.subscribe("team.spawn.*")
      Loomkin.Signals.subscribe("team.complexity.*")

      # Boost score via conflicts (25 pts) + debates (15 pts) + pending tasks (10 pts)
      for _ <- 1..5, do: CollaborationMetrics.record_event(team_id, :conflict_detected)
      seed_pending_tasks(team_id, 5)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | scores: [0, 0, 0, 0, 0],
            pending_events: %{conflicts: 5, debates: 3, tasks_created: 0}
        }
      end)

      send(pid, :check_complexity)
      _ = :sys.get_state(pid)

      assert_receive {:signal, %Jido.Signal{type: "team.complexity.threshold_reached"}}, 1000
      assert_receive {:signal, %Jido.Signal{type: "team.spawn.suggested"}}, 1000

      GenServer.stop(pid)
    end
  end

  describe "cooldown" do
    test "does not re-trigger within cooldown period", %{team_id: team_id} do
      pid = start_monitor(team_id, spawn_cooldown: 300_000, threshold: 10)

      Loomkin.Signals.subscribe("team.spawn.*")

      for _ <- 1..5, do: CollaborationMetrics.record_event(team_id, :conflict_detected)
      seed_pending_tasks(team_id, 5)

      # Set state as if we just suggested a spawn (cooldown not elapsed)
      :sys.replace_state(pid, fn state ->
        %{
          state
          | scores: [0, 0, 0],
            last_spawn_suggested_at: System.monotonic_time(:millisecond),
            pending_events: %{conflicts: 5, debates: 3, tasks_created: 0}
        }
      end)

      send(pid, :check_complexity)
      _ = :sys.get_state(pid)

      refute_receive {:signal, %Jido.Signal{type: "team.spawn.suggested"}}, 200

      GenServer.stop(pid)
    end
  end

  describe "recommend_specialist" do
    test "suggests mediator for conflicts", %{team_id: team_id} do
      pid = start_monitor(team_id, threshold: 10)

      Loomkin.Signals.subscribe("team.spawn.*")

      # Many conflicts, few debates — should recommend mediator
      for _ <- 1..5, do: CollaborationMetrics.record_event(team_id, :conflict_detected)
      seed_pending_tasks(team_id, 5)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | scores: [0, 0, 0],
            pending_events: %{conflicts: 5, debates: 0, tasks_created: 0}
        }
      end)

      send(pid, :check_complexity)
      _ = :sys.get_state(pid)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.spawn.suggested",
                        data: %{specialist_type: "mediator"}
                      }},
                     1000

      GenServer.stop(pid)
    end

    test "suggests analyst for long debates", %{team_id: team_id} do
      pid = start_monitor(team_id, threshold: 10)

      Loomkin.Signals.subscribe("team.spawn.*")

      # No conflicts, many debates + high-confidence options to boost score
      # Each high-confidence option adds 4 points (up to 20)
      for i <- 1..3 do
        Graph.add_node(%{
          node_type: :option,
          title: "option-#{i}",
          confidence: 80,
          status: :active,
          metadata: %{"team_id" => team_id}
        })
      end

      :sys.replace_state(pid, fn state ->
        %{
          state
          | scores: [0, 0, 0],
            pending_events: %{conflicts: 0, debates: 5, tasks_created: 0}
        }
      end)

      send(pid, :check_complexity)
      _ = :sys.get_state(pid)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "team.spawn.suggested",
                        data: %{specialist_type: "analyst"}
                      }},
                     1000

      GenServer.stop(pid)
    end
  end

  describe "periodic check" do
    test "schedules next check after handling", %{team_id: team_id} do
      pid = start_monitor(team_id, check_interval: 50)

      Process.sleep(150)

      state = :sys.get_state(pid)
      assert length(state.scores) >= 2

      GenServer.stop(pid)
    end
  end
end
