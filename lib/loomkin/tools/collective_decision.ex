defmodule Loomkin.Tools.CollectiveDecision do
  @moduledoc """
  Tool for initiating a weighted collective vote among team agents.

  Collects votes from specified participants (or all team agents), weights them
  by role relevance, capability score, and agent-stated confidence, then logs
  the result to the decision graph.
  """

  use Jido.Action,
    name: "collective_decision",
    description:
      "Initiate a weighted collective vote on a topic among team agents. " <>
        "Returns both raw and weighted tallies with the winning option.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      topic: [type: :string, required: true, doc: "Decision topic to vote on"],
      options: [type: {:list, :string}, required: true, doc: "List of options to vote on"],
      scope: [
        type: :string,
        doc:
          "Decision scope/domain for weighting (e.g. code, architecture, testing, research). Defaults to 'general'"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.ConsensusPolicy
  alias Loomkin.Teams.Context

  @vote_timeout_ms 30_000

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    topic = param!(params, :topic)
    options = param!(params, :options)
    from = param!(context, :agent_name)

    # Load policy from config, use scope param as override
    policy = Loomkin.Config.consensus_policy()
    scope = param(params, :scope, policy.scope)

    agents = Context.list_agents(team_id)

    if length(agents) < 2 do
      {:error, "Need at least 2 agents for a collective decision, found #{length(agents)}"}
    else
      vote_id = Ecto.UUID.generate()
      vote_topic = "team:#{team_id}:vote:#{vote_id}"
      Phoenix.PubSub.subscribe(Loomkin.PubSub, vote_topic)

      # Request votes from all agents
      Enum.each(agents, fn agent ->
        Comms.send_to(team_id, agent.name, {
          :vote_request,
          vote_id,
          topic,
          options,
          scope
        })
      end)

      participant_names = Enum.map(agents, & &1.name)
      votes = collect_votes(vote_id, participant_names, @vote_timeout_ms)

      result =
        Loomkin.Teams.Debate.tally_weighted_votes(
          votes,
          agents,
          topic,
          scope
        )

      # Check quorum using policy
      consensus? =
        ConsensusPolicy.quorum_met?(
          policy.quorum,
          result.winning_weight_pct,
          length(votes),
          length(agents)
        )

      result = Map.put(result, :consensus?, consensus?)

      # Log to decision graph
      {:ok, node} =
        Graph.add_node(%{
          node_type: :decision,
          title: "Collective decision: #{truncate(topic, 80)}",
          description: topic,
          confidence: if(consensus?, do: 90, else: round(result.winning_weight_pct)),
          agent_name: to_string(from),
          metadata: %{
            "vote_id" => vote_id,
            "scope" => scope,
            "options" => options,
            "raw_tallies" => result.raw_tallies,
            "weighted_tallies" => result.weighted_tallies,
            "vote_weights" => result.vote_weights,
            "winner" => result.winner,
            "consensus" => consensus?,
            "quorum" => to_string(policy.quorum),
            "on_deadlock" => to_string(policy.on_deadlock),
            "team_id" => team_id
          }
        })

      Comms.broadcast_decision(team_id, node.id, to_string(from))

      # Broadcast result to team
      Comms.broadcast(team_id, {:collective_decision_result, vote_id, result})

      summary = format_result(result, topic)
      {:ok, %{result: summary}}
    end
  end

  defp collect_votes(vote_id, participants, timeout) do
    expected = MapSet.new(participants)
    do_collect_votes(vote_id, expected, MapSet.new(), [], timeout)
  end

  defp do_collect_votes(_vote_id, expected, received, acc, _timeout)
       when expected == received do
    acc
  end

  defp do_collect_votes(vote_id, expected, received, acc, timeout) do
    receive do
      {:vote_response, ^vote_id, response} ->
        from = response.from

        if MapSet.member?(expected, from) and not MapSet.member?(received, from) do
          do_collect_votes(
            vote_id,
            expected,
            MapSet.put(received, from),
            [response | acc],
            timeout
          )
        else
          do_collect_votes(vote_id, expected, received, acc, timeout)
        end
    after
      timeout -> acc
    end
  end

  defp format_result(result, topic) do
    weighted_lines =
      result.weighted_tallies
      |> Enum.sort_by(fn {_opt, weight} -> weight end, :desc)
      |> Enum.map_join("\n", fn {opt, weight} ->
        raw = Map.get(result.raw_tallies, opt, 0)
        "  #{opt}: #{Float.round(weight, 2)} weighted (#{raw} raw votes)"
      end)

    weight_lines =
      result.vote_weights
      |> Enum.map_join("\n", fn {agent, weight} ->
        "  #{agent}: #{Float.round(weight, 2)}"
      end)

    """
    Collective Decision on "#{topic}":
    Winner: #{result.winner || "No votes cast"}
    Consensus: #{result.consensus?}

    Weighted Tallies:
    #{weighted_lines}

    Vote Weights:
    #{weight_lines}
    """
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "..."
end
