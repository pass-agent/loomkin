defmodule Loomkin.Tools.TeamProgressTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.Manager
  alias Loomkin.Tools.TeamProgress

  defp run_progress(team_id) do
    TeamProgress.run(%{team_id: team_id}, %{})
  end

  describe "team_progress with keepers" do
    test "returns ok when team has only keepers registered" do
      {:ok, team_id} = Manager.create_team(name: "keeper-only-progress")

      parent = self()

      keeper_pid =
        spawn_link(fn ->
          {:ok, _} =
            Registry.register(
              Loomkin.Teams.AgentRegistry,
              {team_id, "keeper:abc-123"},
              %{type: :keeper, topic: "test", tokens: 100, source_agent: "coder"}
            )

          send(parent, :keeper_registered)
          Process.sleep(:infinity)
        end)

      assert_receive :keeper_registered
      on_exit(fn -> Process.exit(keeper_pid, :kill) end)

      assert {:ok, %{result: result}} = run_progress(team_id)
      assert result =~ "Agents:"
      assert result =~ "(none)"
    end

    test "returns ok with zero agents and zero keepers" do
      {:ok, team_id} = Manager.create_team(name: "empty-progress")

      assert {:ok, %{result: result}} = run_progress(team_id)
      assert result =~ "Agents:"
      assert result =~ "(none)"
    end

    test "lists only real agents when keepers are also present" do
      {:ok, team_id} = Manager.create_team(name: "mixed-progress")

      # Register a real agent from test process
      {:ok, _} =
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {team_id, "researcher-1"},
          %{role: :researcher, status: :working}
        )

      parent = self()

      keeper_pid =
        spawn_link(fn ->
          {:ok, _} =
            Registry.register(
              Loomkin.Teams.AgentRegistry,
              {team_id, "keeper:xyz-789"},
              %{type: :keeper, topic: "research notes", tokens: 500, source_agent: "researcher-1"}
            )

          send(parent, :keeper_registered)
          Process.sleep(:infinity)
        end)

      assert_receive :keeper_registered
      on_exit(fn -> Process.exit(keeper_pid, :kill) end)

      assert {:ok, %{result: result}} = run_progress(team_id)
      assert result =~ "researcher-1 (researcher): working"
      refute result =~ "keeper"
    end

    test "output contains all expected sections" do
      {:ok, team_id} = Manager.create_team(name: "sections-progress")

      assert {:ok, %{result: result}} = run_progress(team_id)
      assert result =~ "Agents:"
      assert result =~ "Tasks"
      assert result =~ "Region Claims:"
      assert result =~ "Budget:"
      assert result =~ "Spent: $"
    end
  end
end
