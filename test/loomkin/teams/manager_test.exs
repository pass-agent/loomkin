defmodule Loomkin.Teams.ManagerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Manager

  setup do
    :ok
  end

  describe "create_team/1" do
    test "returns {:ok, team_id} and creates ETS table" do
      {:ok, team_id} = Manager.create_team(name: "test-team")
      assert is_binary(team_id)
      assert String.starts_with?(team_id, "test-team-")

      # ETS table should exist via registry
      assert {:ok, ref} = Loomkin.Teams.TableRegistry.get_table(team_id)
      assert :ets.info(ref) != :undefined
    end

    test "stores metadata in ETS" do
      {:ok, team_id} = Manager.create_team(name: "meta-team", project_path: "/tmp/proj")
      table = Loomkin.Teams.TableRegistry.get_table!(team_id)

      [{:meta, meta}] = :ets.lookup(table, :meta)
      assert meta.id == team_id
      assert meta.name == "meta-team"
      assert meta.project_path == "/tmp/proj"
      assert %DateTime{} = meta.created_at
    end

    test "raises ArgumentError when name is missing" do
      assert_raise ArgumentError, ":name is required", fn ->
        Manager.create_team([])
      end
    end
  end

  describe "generate_team_id (via create_team)" do
    test "produces URL-safe IDs" do
      {:ok, team_id} = Manager.create_team(name: "My Cool Team!")
      assert team_id =~ ~r/^[a-z0-9-]+-[A-Za-z0-9_-]+$/
    end

    test "truncates long names to 20 chars before suffix" do
      {:ok, team_id} = Manager.create_team(name: String.duplicate("a", 50))
      # prefix is 20 chars, then "-", then Base64 suffix (6 chars for 4 bytes)
      [prefix | _rest] = String.split(team_id, "-") |> Enum.take(1)
      assert String.length(prefix) <= 20
    end

    test "generates unique IDs for same name" do
      {:ok, id1} = Manager.create_team(name: "dup")
      # Need to clean up first ETS table so second create doesn't collide
      {:ok, id2} = Manager.create_team(name: "dup")
      refute id1 == id2
    end
  end

  describe "list_agents/1" do
    test "returns empty list for team with no agents" do
      {:ok, team_id} = Manager.create_team(name: "empty-team")
      assert Manager.list_agents(team_id) == []
    end

    test "returns empty list for nonexistent team" do
      assert Manager.list_agents("nonexistent-team-xyz") == []
    end
  end

  describe "find_agent/2" do
    test "returns :error for nonexistent agent" do
      {:ok, team_id} = Manager.create_team(name: "find-test")
      assert Manager.find_agent(team_id, "no-such-agent") == :error
    end

    test "returns :error for nonexistent team" do
      assert Manager.find_agent("nonexistent-team", "agent") == :error
    end

    test "finds agent registered in the AgentRegistry" do
      {:ok, team_id} = Manager.create_team(name: "find-reg-test")

      # Manually register a process in the AgentRegistry to simulate an agent
      {:ok, _} =
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {team_id, "test-agent"},
          %{role: :coder, status: :idle}
        )

      assert {:ok, pid} = Manager.find_agent(team_id, "test-agent")
      assert pid == self()
    end
  end

  describe "list_agents/1 with registered agents" do
    test "lists agents registered in the AgentRegistry" do
      {:ok, team_id} = Manager.create_team(name: "list-reg-test")

      # Register a process to simulate an agent
      {:ok, _} =
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {team_id, "agent-1"},
          %{role: :coder, status: :idle}
        )

      agents = Manager.list_agents(team_id)
      assert length(agents) == 1
      assert [%{name: "agent-1", role: :coder, status: :idle}] = agents
    end
  end

  describe "dissolve_team/1" do
    test "cleans up ETS table" do
      {:ok, team_id} = Manager.create_team(name: "dissolve-test")
      {:ok, ref} = Loomkin.Teams.TableRegistry.get_table(team_id)
      assert :ets.info(ref) != :undefined

      assert :ok = Manager.dissolve_team(team_id)
      assert :ets.info(ref) == :undefined
      assert {:error, :not_found} = Loomkin.Teams.TableRegistry.get_table(team_id)
    end

    test "is idempotent — calling twice does not crash" do
      {:ok, team_id} = Manager.create_team(name: "idempotent-test")
      assert :ok = Manager.dissolve_team(team_id)
      assert :ok = Manager.dissolve_team(team_id)
    end

    test "resets RateLimiter budget" do
      {:ok, team_id} = Manager.create_team(name: "budget-test")

      # Record some usage so there's budget state to reset
      Loomkin.Teams.RateLimiter.record_usage(team_id, "agent-1", %{tokens: 100, cost: 0.01})
      budget_before = Loomkin.Teams.RateLimiter.get_budget(team_id)
      assert budget_before.spent > 0

      Manager.dissolve_team(team_id)

      # After dissolution, budget should be reset (fresh state)
      budget_after = Loomkin.Teams.RateLimiter.get_budget(team_id)
      assert budget_after.spent == 0.0
    end

    test "broadcasts :team_dissolved event" do
      {:ok, team_id} = Manager.create_team(name: "broadcast-test")
      Phoenix.PubSub.subscribe(Loomkin.PubSub, "team:#{team_id}")

      Manager.dissolve_team(team_id)

      assert_receive {:team_dissolved, ^team_id}
    end
  end

  describe "list_agents/1 excludes keepers" do
    test "returns empty list when team has only keepers" do
      {:ok, team_id} = Manager.create_team(name: "only-keepers")

      # Register a keeper entry (same shape as ContextKeeper.start_link registers)
      {:ok, _} =
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {team_id, "keeper:abc-123"},
          %{type: :keeper, topic: "test topic", tokens: 100, source_agent: "coder"}
        )

      assert Manager.list_agents(team_id) == []
    end

    test "returns only agents when team has both agents and keepers" do
      {:ok, team_id} = Manager.create_team(name: "mixed-team")

      # Register a real agent
      {:ok, _} =
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {team_id, "coder-1"},
          %{role: :coder, status: :idle}
        )

      # Spawn keeper in a separate process with explicit handshake
      parent = self()

      keeper_pid =
        spawn_link(fn ->
          {:ok, _} =
            Registry.register(
              Loomkin.Teams.AgentRegistry,
              {team_id, "keeper:def-456"},
              %{type: :keeper, topic: "context", tokens: 50, source_agent: "coder-1"}
            )

          send(parent, :keeper_registered)
          Process.sleep(:infinity)
        end)

      assert_receive :keeper_registered
      on_exit(fn -> Process.exit(keeper_pid, :kill) end)

      agents = Manager.list_agents(team_id)
      assert length(agents) == 1
      assert [%{name: "coder-1", role: :coder, status: :idle}] = agents
    end

    test "returns all agents when no keepers are present" do
      {:ok, team_id} = Manager.create_team(name: "agents-only")

      {:ok, _} =
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {team_id, "researcher-1"},
          %{role: :researcher, status: :working}
        )

      agents = Manager.list_agents(team_id)
      assert length(agents) == 1
      assert [%{name: "researcher-1", role: :researcher, status: :working}] = agents
    end

    test "handles multiple keepers without leaking any into agent list" do
      {:ok, team_id} = Manager.create_team(name: "multi-keeper")

      # Register an agent from the test process
      {:ok, _} =
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {team_id, "lead-1"},
          %{role: :lead, status: :idle}
        )

      # Register multiple keepers with explicit handshake
      parent = self()

      keeper_pids =
        Enum.map(1..3, fn i ->
          spawn_link(fn ->
            {:ok, _} =
              Registry.register(
                Loomkin.Teams.AgentRegistry,
                {team_id, "keeper:keeper-#{i}"},
                %{type: :keeper, topic: "topic-#{i}", tokens: i * 100, source_agent: "lead-1"}
              )

            send(parent, {:keeper_registered, i})
            Process.sleep(:infinity)
          end)
        end)

      for i <- 1..3, do: assert_receive({:keeper_registered, ^i})
      on_exit(fn -> Enum.each(keeper_pids, &Process.exit(&1, :kill)) end)

      agents = Manager.list_agents(team_id)
      assert length(agents) == 1
      assert [%{name: "lead-1", role: :lead}] = agents
    end
  end

  describe "stop_agent/2" do
    test "returns :ok for nonexistent agent" do
      {:ok, team_id} = Manager.create_team(name: "stop-test")
      assert :ok = Manager.stop_agent(team_id, "no-such-agent")
    end
  end
end
