defmodule Loomkin.Tools.PeerDiscoveryTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.Manager
  alias Loomkin.Tools.PeerDiscovery

  setup do
    {:ok, team_id} = Manager.create_team(name: "discovery-tool-test")

    on_exit(fn ->
      DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
      end)

      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp context(name \\ "alice"), do: %{agent_name: name}

  describe "run/2" do
    test "broadcasts discovery to team", %{team_id: team_id} do
      params = %{team_id: team_id, content: "Found a bug in auth.ex"}
      assert {:ok, %{result: result}} = PeerDiscovery.run(params, context())
      assert result =~ "Discovery broadcast to team"
    end

    test "returns error when team table does not exist" do
      params = %{team_id: "nonexistent-team", content: "test discovery"}
      assert {:error, msg} = PeerDiscovery.run(params, context())
      assert msg =~ "No active team session"
      assert msg =~ "nonexistent-team"
    end

    test "returns error for default team_id when no table exists" do
      params = %{team_id: "default", content: "test discovery"}
      assert {:error, msg} = PeerDiscovery.run(params, context())
      assert msg =~ "No active team session"
    end
  end
end
