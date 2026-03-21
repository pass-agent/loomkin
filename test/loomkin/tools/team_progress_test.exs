defmodule Loomkin.Tools.TeamProgressTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.Manager
  alias Loomkin.Tools.TeamProgress

  defp run_progress(team_id) do
    TeamProgress.run(%{team_id: team_id}, %{})
  end

  describe "team_progress" do
    test "returns ok with zero agents" do
      {:ok, team_id} = Manager.create_team(name: "empty-progress")

      assert {:ok, %{result: result}} = run_progress(team_id)
      assert result =~ "Agents:"
      assert result =~ "(none)"
    end

    test "lists agents in progress output" do
      {:ok, team_id} = Manager.create_team(name: "mixed-progress")

      {:ok, _} =
        Registry.register(
          Loomkin.Teams.AgentRegistry,
          {team_id, "researcher-1"},
          %{role: :researcher, status: :working}
        )

      assert {:ok, %{result: result}} = run_progress(team_id)
      assert result =~ "researcher-1 (researcher): working"
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
