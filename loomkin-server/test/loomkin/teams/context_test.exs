defmodule Loomkin.Teams.ContextTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.{Context, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "ctx-test")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  # -- Agent Roster --

  describe "register_agent/3 and get_agent/2" do
    test "registers and retrieves agent info", %{team_id: team_id} do
      info = %{role: :coder, status: :idle, model: "anthropic:claude-sonnet-4-6"}
      assert :ok = Context.register_agent(team_id, "alice", info)
      assert {:ok, ^info} = Context.get_agent(team_id, "alice")
    end

    test "returns :error for unknown agent", %{team_id: team_id} do
      assert :error = Context.get_agent(team_id, "nobody")
    end
  end

  describe "update_agent_status/3" do
    test "updates existing agent status", %{team_id: team_id} do
      Context.register_agent(team_id, "bob", %{role: :researcher, status: :idle})
      assert :ok = Context.update_agent_status(team_id, "bob", :working)
      assert {:ok, %{status: :working}} = Context.get_agent(team_id, "bob")
    end

    test "returns :error for unregistered agent", %{team_id: team_id} do
      assert :error = Context.update_agent_status(team_id, "ghost", :working)
    end
  end

  describe "list_agents/1" do
    test "lists all registered agents", %{team_id: team_id} do
      Context.register_agent(team_id, "a1", %{role: :coder, status: :idle})
      Context.register_agent(team_id, "a2", %{role: :reviewer, status: :working})

      agents = Context.list_agents(team_id)
      assert length(agents) == 2
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["a1", "a2"]
    end

    test "returns empty list for nonexistent team" do
      assert Context.list_agents("no-such-team") == []
    end
  end

  # -- Shared Discoveries --

  describe "add_discovery/2 and list_discoveries/1" do
    test "stores and retrieves discoveries in order", %{team_id: team_id} do
      Context.add_discovery(team_id, %{from: "alice", type: :discovery, content: "first"})
      Context.add_discovery(team_id, %{from: "bob", type: :error, content: "second"})

      discoveries = Context.list_discoveries(team_id)
      assert length(discoveries) == 2
      assert Enum.at(discoveries, 0).content == "first"
      assert Enum.at(discoveries, 1).content == "second"
    end
  end

  describe "list_discoveries/2 with type filter" do
    test "filters discoveries by type", %{team_id: team_id} do
      Context.add_discovery(team_id, %{from: "alice", type: :discovery, content: "found module"})
      Context.add_discovery(team_id, %{from: "bob", type: :error, content: "compile error"})
      Context.add_discovery(team_id, %{from: "carol", type: :discovery, content: "found test"})

      discoveries = Context.list_discoveries(team_id, type: :discovery)
      assert length(discoveries) == 2
      assert Enum.all?(discoveries, &(&1.type == :discovery))
    end
  end

  # -- Region-Level Locking --

  describe "claim_region/4" do
    test "claims a region successfully when no conflict", %{team_id: team_id} do
      assert :ok = Context.claim_region(team_id, "alice", "lib/foo.ex", {:lines, 1, 10})
    end

    test "two agents can work on non-overlapping regions of the same file", %{team_id: team_id} do
      assert :ok = Context.claim_region(team_id, "alice", "lib/foo.ex", {:lines, 1, 10})
      assert :ok = Context.claim_region(team_id, "bob", "lib/foo.ex", {:lines, 20, 30})
    end

    test "detects conflict on overlapping line regions", %{team_id: team_id} do
      assert :ok = Context.claim_region(team_id, "alice", "lib/foo.ex", {:lines, 1, 15})

      assert {:conflict, "alice", {:lines, 1, 15}} =
               Context.claim_region(team_id, "bob", "lib/foo.ex", {:lines, 10, 20})
    end

    test "whole_file conflicts with any region", %{team_id: team_id} do
      assert :ok = Context.claim_region(team_id, "alice", "lib/bar.ex", {:lines, 5, 10})

      assert {:conflict, "alice", {:lines, 5, 10}} =
               Context.claim_region(team_id, "bob", "lib/bar.ex", :whole_file)
    end

    test "symbol region conflicts with any region (treated as whole_file)", %{team_id: team_id} do
      assert :ok = Context.claim_region(team_id, "alice", "lib/baz.ex", {:lines, 1, 5})

      assert {:conflict, "alice", {:lines, 1, 5}} =
               Context.claim_region(team_id, "bob", "lib/baz.ex", {:symbol, "Mod.func/2"})
    end

    test "same agent can update their own claim without conflict", %{team_id: team_id} do
      assert :ok = Context.claim_region(team_id, "alice", "lib/foo.ex", {:lines, 1, 10})
      assert :ok = Context.claim_region(team_id, "alice", "lib/foo.ex", {:lines, 1, 20})
    end

    test "different files never conflict", %{team_id: team_id} do
      assert :ok = Context.claim_region(team_id, "alice", "lib/a.ex", :whole_file)
      assert :ok = Context.claim_region(team_id, "bob", "lib/b.ex", :whole_file)
    end
  end

  describe "release_region/3" do
    test "releases a claimed region", %{team_id: team_id} do
      Context.claim_region(team_id, "alice", "lib/foo.ex", {:lines, 1, 10})
      assert :ok = Context.release_region(team_id, "alice", "lib/foo.ex")
      assert Context.list_claims(team_id, "lib/foo.ex") == []
    end

    test "release on nonexistent claim is a no-op", %{team_id: team_id} do
      assert :ok = Context.release_region(team_id, "nobody", "lib/foo.ex")
    end
  end

  describe "claim expiry" do
    test "expired claims are filtered out of list_claims", %{team_id: team_id} do
      # Insert a claim with an artificially old timestamp
      table = Loomkin.Teams.TableRegistry.get_table!(team_id)
      old_time = System.monotonic_time(:millisecond) - 6 * 60 * 1000

      claim = %{
        agent: "stale",
        path: "lib/old.ex",
        region: :whole_file,
        claimed_at: old_time
      }

      :ets.insert(table, {{:claim, "lib/old.ex", "stale"}, claim})

      assert Context.list_claims(team_id, "lib/old.ex") == []
    end

    test "expired claims do not cause conflicts", %{team_id: team_id} do
      table = Loomkin.Teams.TableRegistry.get_table!(team_id)
      old_time = System.monotonic_time(:millisecond) - 6 * 60 * 1000

      claim = %{
        agent: "stale",
        path: "lib/old.ex",
        region: :whole_file,
        claimed_at: old_time
      }

      :ets.insert(table, {{:claim, "lib/old.ex", "stale"}, claim})

      # Should succeed since old claim is expired
      assert :ok = Context.claim_region(team_id, "fresh", "lib/old.ex", :whole_file)
    end
  end

  describe "list_all_claims/1" do
    test "returns all active claims across files", %{team_id: team_id} do
      Context.claim_region(team_id, "alice", "lib/a.ex", :whole_file)
      Context.claim_region(team_id, "bob", "lib/b.ex", {:lines, 1, 5})

      claims = Context.list_all_claims(team_id)
      assert length(claims) == 2
    end
  end

  describe "broadcast_intent/4" do
    test "broadcasts intent message to team topic", %{team_id: team_id} do
      Loomkin.Signals.subscribe("collaboration.**")

      Context.broadcast_intent(team_id, "alice", "lib/foo.ex", "refactoring module")

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:intent, "alice", "lib/foo.ex", "refactoring module"}}
                      }},
                     500
    end
  end

  # -- Task Summaries --

  describe "task cache" do
    test "caches and retrieves a task", %{team_id: team_id} do
      task = %{title: "Fix bug", status: :in_progress, owner: "alice"}
      assert :ok = Context.cache_task(team_id, "t1", task)
      assert {:ok, ^task} = Context.get_cached_task(team_id, "t1")
    end

    test "returns :error for unknown task", %{team_id: team_id} do
      assert :error = Context.get_cached_task(team_id, "nope")
    end

    test "lists all cached tasks with ids", %{team_id: team_id} do
      Context.cache_task(team_id, "t1", %{title: "A", status: :pending, owner: nil})
      Context.cache_task(team_id, "t2", %{title: "B", status: :done, owner: "bob"})

      tasks = Context.list_cached_tasks(team_id)
      assert length(tasks) == 2
      ids = Enum.map(tasks, & &1.id) |> Enum.sort()
      assert ids == ["t1", "t2"]
    end
  end
end
