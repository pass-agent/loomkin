defmodule Loomkin.Teams.StructuredResultsTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Manager
  alias Loomkin.Teams.Tasks

  setup do
    {:ok, team_id} = Manager.create_team(name: "structured-test")
    Comms.subscribe(team_id, "listener")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "complete_task/2 with structured fields" do
    test "accepts a map with structured fields", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Structured test"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)

      attrs = %{
        result: "Implemented auth module",
        actions_taken: ["Created lib/auth.ex", "Updated router"],
        discoveries: ["Phoenix 1.8 has built-in token verification"],
        files_changed: ["lib/auth.ex", "lib/router.ex"],
        decisions_made: ["Used JWT over session tokens for statelessness"],
        open_questions: ["Refresh token rotation strategy TBD"]
      }

      assert {:ok, completed} = Tasks.complete_task(task.id, attrs)
      assert completed.status == :completed
      assert completed.result == "Implemented auth module"
      assert completed.actions_taken == ["Created lib/auth.ex", "Updated router"]
      assert completed.discoveries == ["Phoenix 1.8 has built-in token verification"]
      assert completed.files_changed == ["lib/auth.ex", "lib/router.ex"]
      assert completed.decisions_made == ["Used JWT over session tokens for statelessness"]
      assert completed.open_questions == ["Refresh token rotation strategy TBD"]
    end

    test "backward compat: accepts a plain string result", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "String test"})
      Tasks.assign_task(task.id, "coder")
      Tasks.start_task(task.id)

      assert {:ok, completed} = Tasks.complete_task(task.id, "Plain result")
      assert completed.status == :completed
      assert completed.result == "Plain result"
      assert completed.actions_taken == []
      assert completed.discoveries == []
      assert completed.files_changed == []
      assert completed.decisions_made == []
      assert completed.open_questions == []
    end

    test "accepts a map with only result (no structured fields)", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "Minimal map test"})
      Tasks.assign_task(task.id, "coder")

      assert {:ok, completed} = Tasks.complete_task(task.id, %{result: "Just a result"})
      assert completed.result == "Just a result"
      assert completed.actions_taken == []
      assert completed.files_changed == []
    end

    test "accepts string-keyed maps (from JSON tool params)", %{team_id: team_id} do
      {:ok, task} = Tasks.create_task(team_id, %{title: "String keys test"})
      Tasks.assign_task(task.id, "coder")

      attrs = %{
        "result" => "Done",
        "files_changed" => ["lib/foo.ex"],
        "decisions_made" => ["Chose approach A"]
      }

      assert {:ok, completed} = Tasks.complete_task(task.id, attrs)
      assert completed.result == "Done"
      assert completed.files_changed == ["lib/foo.ex"]
      assert completed.decisions_made == ["Chose approach A"]
    end
  end

  describe "get_predecessor_outputs/1 with structured fields" do
    test "returns structured fields from completed predecessors", %{team_id: team_id} do
      {:ok, producer} = Tasks.create_task(team_id, %{title: "Producer"})
      {:ok, consumer} = Tasks.create_task(team_id, %{title: "Consumer"})
      Tasks.add_dependency(consumer.id, producer.id, :requires_output)

      Tasks.assign_task(producer.id, "coder")

      Tasks.complete_task(producer.id, %{
        result: "Built the API",
        files_changed: ["lib/api.ex", "lib/router.ex"],
        discoveries: ["Rate limiting needed"],
        decisions_made: ["REST over GraphQL"],
        open_questions: ["Auth strategy?"]
      })

      outputs = Tasks.get_predecessor_outputs(consumer.id)
      assert length(outputs) == 1

      [output] = outputs
      assert output.title == "Producer"
      assert output.result == "Built the API"
      assert output.files_changed == ["lib/api.ex", "lib/router.ex"]
      assert output.discoveries == ["Rate limiting needed"]
      assert output.decisions_made == ["REST over GraphQL"]
      assert output.open_questions == ["Auth strategy?"]
      assert output.partial == false
    end

    test "returns empty lists for predecessors without structured fields", %{team_id: team_id} do
      {:ok, producer} = Tasks.create_task(team_id, %{title: "Old-style"})
      {:ok, consumer} = Tasks.create_task(team_id, %{title: "Consumer"})
      Tasks.add_dependency(consumer.id, producer.id, :requires_output)

      Tasks.assign_task(producer.id, "coder")
      Tasks.complete_task(producer.id, "plain result")

      outputs = Tasks.get_predecessor_outputs(consumer.id)
      assert length(outputs) == 1

      [output] = outputs
      assert output.result == "plain result"
      assert output.files_changed == []
      assert output.actions_taken == []
    end

    test "composes outputs from multiple predecessors", %{team_id: team_id} do
      {:ok, p1} = Tasks.create_task(team_id, %{title: "Research"})
      {:ok, p2} = Tasks.create_task(team_id, %{title: "Design"})
      {:ok, consumer} = Tasks.create_task(team_id, %{title: "Implement"})

      Tasks.add_dependency(consumer.id, p1.id, :requires_output)
      Tasks.add_dependency(consumer.id, p2.id, :requires_output)

      Tasks.assign_task(p1.id, "researcher")

      Tasks.complete_task(p1.id, %{
        result: "Found patterns",
        discoveries: ["Pattern A", "Pattern B"]
      })

      Tasks.assign_task(p2.id, "researcher")

      Tasks.complete_task(p2.id, %{
        result: "Designed schema",
        files_changed: ["docs/schema.md"],
        decisions_made: ["Use ETS for hot state"]
      })

      outputs = Tasks.get_predecessor_outputs(consumer.id)
      assert length(outputs) == 2

      titles = Enum.map(outputs, & &1.title) |> Enum.sort()
      assert titles == ["Design", "Research"]
    end
  end
end
