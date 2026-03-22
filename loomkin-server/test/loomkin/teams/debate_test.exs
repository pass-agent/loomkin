defmodule Loomkin.Teams.DebateTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Teams.{Debate, Manager}
  alias Loomkin.Decisions.Graph

  setup do
    {:ok, team_id} = Manager.create_team(name: "debate-test")

    on_exit(fn ->
      Loomkin.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "initiate_debate/4" do
    test "returns error with fewer than 2 participants", %{team_id: team_id} do
      assert {:error, :insufficient_participants} =
               Debate.initiate_debate(team_id, "test topic", ["alice"])
    end

    test "returns error with empty participants", %{team_id: team_id} do
      assert {:error, :insufficient_participants} =
               Debate.initiate_debate(team_id, "test topic", [])
    end

    test "sends debate_start to all participants", %{team_id: team_id} do
      # Subscribe as both participants
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      # Run debate in a task so we can respond to messages
      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "best framework", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 100
          )
        end)

      # Both should receive debate_start via signal
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{
                          message: {:debate_start, debate_id, "best framework", ["alice", "bob"]}
                        }
                      }},
                     1_000

      assert is_binary(debate_id)

      # Let it timeout (we won't respond)
      {:ok, result} = Task.await(task, 5_000)
      assert is_map(result)
      assert is_list(result.rounds)
      assert is_map(result.votes)
    end

    test "collects proposals and logs to decision graph", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "architecture", ["alice", "bob"],
            max_rounds: 1,
            round_timeout_ms: 500
          )
        end)

      # Wait for propose phase
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_start, debate_id, "architecture", _}}
                      }},
                     1_000

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_propose, ^debate_id, 1, "architecture"}}
                      }},
                     1_000

      # Submit proposals
      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "alice",
        content: "Use microservices",
        confidence: 70
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "bob",
        content: "Use monolith",
        confidence: 80
      })

      # Wait for critique phase and let it timeout
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_critique, ^debate_id, 1, _others}}
                      }},
                     1_000

      # Let remaining phases timeout
      {:ok, result} = Task.await(task, 10_000)

      assert length(result.rounds) == 1
      round = hd(result.rounds)
      assert length(round.proposals) == 2

      # Verify nodes were created in decision graph
      nodes = Graph.list_nodes(node_type: :option)
      debate_nodes = Enum.filter(nodes, &(&1.metadata["debate_id"] == debate_id))
      assert length(debate_nodes) >= 2
    end

    test "runs multiple rounds up to max_rounds", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "naming", ["alice", "bob"],
            max_rounds: 2,
            round_timeout_ms: 100
          )
        end)

      # Let all rounds timeout
      {:ok, result} = Task.await(task, 10_000)

      # Should have attempted 2 rounds
      assert length(result.rounds) == 2
    end
  end

  describe "submit_response/4" do
    test "broadcasts response on debate topic", %{team_id: team_id} do
      debate_id = Ecto.UUID.generate()

      # Subscribe to collaboration signals to receive the debate response
      Loomkin.Signals.subscribe("collaboration.**")

      response = %{from: "alice", content: "my proposal"}
      Debate.submit_response(team_id, debate_id, :proposal, response)

      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.debate.response",
                        data: %{debate_id: ^debate_id, phase: :proposal, response: ^response}
                      }},
                     1_000
    end
  end

  describe "voting and consensus" do
    test "tallies votes and determines winner", %{team_id: team_id} do
      Loomkin.Teams.Comms.subscribe(team_id, "alice")
      Loomkin.Teams.Comms.subscribe(team_id, "bob")
      Loomkin.Teams.Comms.subscribe(team_id, "carol")

      task =
        Task.async(fn ->
          Debate.initiate_debate(team_id, "language", ["alice", "bob", "carol"],
            max_rounds: 1,
            round_timeout_ms: 500
          )
        end)

      # Wait for debate_start and get the debate_id
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_start, debate_id, "language", _}}
                      }},
                     1_000

      # Submit proposals
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_propose, ^debate_id, 1, _}}
                      }},
                     1_000

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "alice",
        content: "Elixir"
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "bob",
        content: "Rust"
      })

      Debate.submit_response(team_id, debate_id, :proposal, %{
        from: "carol",
        content: "Go"
      })

      # Skip critique/revise (let them timeout), then submit votes
      assert_receive {:signal,
                      %Jido.Signal{
                        type: "collaboration.peer.message",
                        data: %{message: {:debate_vote, ^debate_id, _proposals}}
                      }},
                     5_000

      Debate.submit_response(team_id, debate_id, :vote, %{from: "alice", choice: "alice"})
      Debate.submit_response(team_id, debate_id, :vote, %{from: "bob", choice: "alice"})
      Debate.submit_response(team_id, debate_id, :vote, %{from: "carol", choice: "bob"})

      {:ok, result} = Task.await(task, 10_000)

      assert result.votes["alice"] == "alice"
      assert result.votes["bob"] == "alice"
      assert result.votes["carol"] == "bob"
      # Default policy is :majority — 2/3 votes (66.7%) > 50% threshold
      assert result.consensus? == true
    end
  end
end
