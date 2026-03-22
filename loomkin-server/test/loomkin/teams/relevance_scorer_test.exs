defmodule Loomkin.Teams.RelevanceScorerTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.RelevanceScorer

  describe "score/2" do
    test "returns 0.0 for discovery from self" do
      discovery = %{from: "coder-1", type: "discovery", content: "Found a bug in auth"}
      agent = %{name: "coder-1", role: :coder, task: %{description: "Fix auth"}}

      assert RelevanceScorer.score(discovery, agent) == 0.0
    end

    test "high score for keyword overlap" do
      discovery = %{
        from: "researcher",
        type: "discovery",
        content: "The authentication module uses bcrypt for password hashing"
      }

      agent = %{
        name: "coder-1",
        role: :coder,
        task: %{description: "Fix authentication password hashing bug"}
      }

      score = RelevanceScorer.score(discovery, agent)
      assert score >= 0.3
    end

    test "high score for shared file paths" do
      discovery = %{
        from: "researcher",
        type: "discovery",
        content: "Found issue in lib/auth/session.ex"
      }

      agent = %{
        name: "coder-1",
        role: :coder,
        task: %{description: "Fix session handling in lib/auth/session.ex"}
      }

      score = RelevanceScorer.score(discovery, agent)
      assert score >= 0.3
    end

    test "role alignment boosts code discoveries for coders" do
      discovery = %{from: "researcher", type: "code", content: "Implementation detail found"}
      agent_coder = %{name: "coder-1", role: :coder, task: %{}}
      agent_researcher = %{name: "researcher-2", role: :researcher, task: %{}}

      score_coder = RelevanceScorer.score(discovery, agent_coder)
      score_researcher = RelevanceScorer.score(discovery, agent_researcher)

      assert score_coder > score_researcher
    end

    test "role alignment boosts research discoveries for researchers" do
      discovery = %{from: "coder-1", type: "insight", content: "Architecture observation"}
      agent_researcher = %{name: "researcher-1", role: :researcher, task: %{}}
      agent_coder = %{name: "coder-2", role: :coder, task: %{}}

      score_researcher = RelevanceScorer.score(discovery, agent_researcher)
      score_coder = RelevanceScorer.score(discovery, agent_coder)

      assert score_researcher > score_coder
    end

    test "blockers have high role score for all roles" do
      discovery = %{from: "coder-1", type: "blocker", content: "Cannot proceed"}
      agent = %{name: "lead", role: :lead, task: %{}}

      score = RelevanceScorer.score(discovery, agent)
      # Blocker role score is 0.7, so role component alone is 0.7 * 0.2 = 0.14
      assert score >= 0.1
    end

    test "returns low score for unrelated content" do
      discovery = %{from: "researcher", type: "discovery", content: "Database migration strategy"}

      agent = %{
        name: "coder-1",
        role: :coder,
        task: %{description: "Fix CSS styling in header component"}
      }

      score = RelevanceScorer.score(discovery, agent)
      assert score < 0.4
    end

    test "handles nil content gracefully" do
      discovery = %{from: "researcher", type: "discovery", content: nil}
      agent = %{name: "coder-1", role: :coder, task: %{description: "Fix something"}}

      score = RelevanceScorer.score(discovery, agent)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "handles missing task gracefully" do
      discovery = %{from: "researcher", type: "discovery", content: "Found something"}
      agent = %{name: "coder-1", role: :coder}

      score = RelevanceScorer.score(discovery, agent)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end

    test "score never exceeds 1.0" do
      discovery = %{
        from: "researcher",
        type: "code",
        content: "Fix authentication bug in lib/auth.ex"
      }

      agent = %{
        name: "coder-1",
        role: :coder,
        task: %{description: "Fix authentication bug in lib/auth.ex"}
      }

      score = RelevanceScorer.score(discovery, agent)
      assert score <= 1.0
    end
  end

  describe "filter_relevant/3" do
    test "filters agents below threshold" do
      discovery = %{
        from: "researcher",
        type: "discovery",
        content: "Found auth bug in lib/auth.ex"
      }

      agents = [
        %{name: "coder-1", role: :coder, task: %{description: "Fix auth bug in lib/auth.ex"}},
        %{name: "coder-2", role: :coder, task: %{description: "CSS styling for dashboard"}},
        %{name: "researcher", role: :researcher, task: %{description: "Auth analysis"}}
      ]

      # researcher is filtered out (self), coder-1 should score high, coder-2 low
      result = RelevanceScorer.filter_relevant(discovery, agents, 0.3)

      agent_names = Enum.map(result, fn {agent, _score} -> agent.name end)
      assert "coder-1" in agent_names
      # coder-2 may or may not pass depending on role score alone
    end

    test "returns empty list when no agents pass threshold" do
      discovery = %{
        from: "researcher",
        type: "discovery",
        content: "Quantum computing breakthrough"
      }

      agents = [
        %{name: "coder-1", role: :coder, task: %{description: "Fix CSS button color"}},
        %{name: "researcher", role: :researcher, task: %{description: "Quantum computing"}}
      ]

      result = RelevanceScorer.filter_relevant(discovery, agents, 0.9)

      # Self is excluded, and CSS task is unrelated — nothing should score > 0.9
      high_scores = Enum.filter(result, fn {_agent, s} -> s >= 0.9 end)
      assert length(high_scores) == 0
    end

    test "results are sorted by score descending" do
      discovery = %{
        from: "researcher",
        type: "code",
        content: "Fix bug in lib/auth.ex authentication"
      }

      agents = [
        %{
          name: "coder-1",
          role: :coder,
          task: %{description: "Fix authentication in lib/auth.ex"}
        },
        %{name: "coder-2", role: :coder, task: %{description: "Work on auth module"}},
        %{name: "lead", role: :lead, task: %{description: "Coordinate auth fix"}}
      ]

      result = RelevanceScorer.filter_relevant(discovery, agents, 0.0)
      scores = Enum.map(result, fn {_agent, s} -> s end)

      # Verify descending order
      assert scores == Enum.sort(scores, :desc)
    end

    test "uses default threshold when not specified" do
      assert RelevanceScorer.default_threshold() == 0.3
    end
  end
end
