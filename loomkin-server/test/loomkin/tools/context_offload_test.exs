defmodule Loomkin.Tools.ContextOffloadTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.Manager
  alias Loomkin.Tools.ContextOffload, as: OffloadTool

  setup do
    {:ok, team_id} = Manager.create_team(name: "ctx-offload-tool-test")

    on_exit(fn ->
      DynamicSupervisor.which_children(Loomkin.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loomkin.Teams.AgentSupervisor, pid)
      end)

      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp build_messages(count) do
    Enum.map(1..count, fn i ->
      role = if rem(i, 2) == 1, do: :user, else: :assistant
      %{role: role, content: "Message #{i} content here"}
    end)
  end

  describe "run/2" do
    test "auto-split offload creates keeper with topic", %{team_id: team_id} do
      messages = build_messages(10)

      params = %{team_id: team_id, topic: "auth research"}

      context = %{
        agent_name: "coder-1",
        team_id: team_id,
        agent_messages: messages
      }

      assert {:ok, %{result: result}} = OffloadTool.run(params, context)
      assert result =~ "Offloaded"
      assert result =~ "messages"
      assert result =~ "topic=auth research"
    end

    test "explicit message_count offload", %{team_id: team_id} do
      messages = build_messages(10)

      params = %{team_id: team_id, topic: "explicit offload", message_count: 4}

      context = %{
        agent_name: "coder-1",
        team_id: team_id,
        agent_messages: messages
      }

      assert {:ok, %{result: result}} = OffloadTool.run(params, context)
      assert result =~ "Offloaded 4 messages"
    end

    test "empty offload returns friendly message", %{team_id: team_id} do
      # Only 2 messages — split_at_topic_boundary returns empty offload for < 4 messages
      messages = build_messages(2)

      params = %{team_id: team_id, topic: "tiny context"}

      context = %{
        agent_name: "coder-1",
        team_id: team_id,
        agent_messages: messages
      }

      assert {:ok, %{result: result}} = OffloadTool.run(params, context)
      assert result =~ "No messages to offload"
    end

    test "offloaded context is queryable via retrieval", %{team_id: team_id} do
      messages = [
        %{role: :user, content: "We decided to use PostgreSQL"},
        %{role: :assistant, content: "PostgreSQL with binary_id primary keys"},
        %{role: :user, content: "Also use Ecto for the ORM"},
        %{role: :assistant, content: "Ecto with changesets for validation"},
        %{role: :user, content: "Deploy to Fly.io"},
        %{role: :assistant, content: "Using Fly machines for workers"}
      ]

      params = %{team_id: team_id, topic: "database decisions", message_count: 4}

      context = %{
        agent_name: "researcher",
        team_id: team_id,
        agent_messages: messages
      }

      assert {:ok, %{result: _}} = OffloadTool.run(params, context)

      # Now retrieve context
      retrieve_params = %{team_id: team_id, query: "database decisions"}

      assert {:ok, %{result: retrieved}} =
               Loomkin.Tools.ContextRetrieve.run(retrieve_params, %{agent_name: "researcher"})

      assert retrieved =~ "PostgreSQL"
    end

    test "works with string keys", %{team_id: team_id} do
      messages = build_messages(10)

      params = %{"team_id" => team_id, "topic" => "string keys", "message_count" => 3}

      context = %{
        agent_name: "coder-1",
        team_id: team_id,
        agent_messages: messages
      }

      assert {:ok, %{result: result}} = OffloadTool.run(params, context)
      assert result =~ "Offloaded 3 messages"
    end
  end
end
