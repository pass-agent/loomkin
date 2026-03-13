defmodule Loomkin.Conversations.Templates do
  @moduledoc "Pre-built persona sets and configurations for common conversation patterns."

  @templates %{
    "brainstorm" => :brainstorm,
    "design_review" => :design_review,
    "red_team" => :red_team,
    "user_panel" => :user_panel
  }

  @doc "Returns a list of available template names."
  @spec list() :: [String.t()]
  def list, do: Map.keys(@templates)

  @doc "Returns a conversation config for the given template name, or {:error, reason}."
  @spec get(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def get(name, topic, context \\ nil) do
    case Map.fetch(@templates, name) do
      {:ok, fun} -> {:ok, apply(__MODULE__, fun, [topic, context])}
      :error -> {:error, "Unknown template: #{name}. Available: #{Enum.join(list(), ", ")}"}
    end
  end

  @doc "Brainstorm template: Innovator + Pragmatist + Critic, round_robin, 8 rounds."
  @spec brainstorm(String.t(), String.t() | nil) :: map()
  def brainstorm(topic, context \\ nil) do
    %{
      topic: topic,
      context: context,
      strategy: :round_robin,
      max_rounds: 8,
      personas: [
        %{
          name: "Innovator",
          perspective: "Pushes for novel, unconventional approaches",
          expertise: "Creative problem solving",
          goal: "Generate unexpected ideas"
        },
        %{
          name: "Pragmatist",
          perspective: "Grounds ideas in practical reality",
          expertise: "Implementation and delivery",
          goal: "Identify what's actually buildable"
        },
        %{
          name: "Critic",
          perspective: "Finds weaknesses and risks",
          expertise: "Risk assessment and edge cases",
          goal: "Stress-test every idea before it's accepted"
        }
      ]
    }
  end

  @doc "Design review template: Tech Lead + Domain Expert + Maintainer, facilitator strategy, 6 rounds."
  @spec design_review(String.t(), String.t() | nil) :: map()
  def design_review(topic, context \\ nil) do
    %{
      topic: topic,
      context: context,
      strategy: :facilitator,
      facilitator: "Tech Lead",
      max_rounds: 6,
      personas: [
        %{
          name: "Tech Lead",
          perspective: "Balances quality with delivery",
          expertise: "Architecture and team dynamics",
          goal: "Drive toward a clear decision"
        },
        %{
          name: "Domain Expert",
          perspective: "Deep knowledge of the problem space",
          expertise: "Business rules and domain modeling",
          goal: "Ensure the design fits the domain"
        },
        %{
          name: "Maintainer",
          perspective: "Thinks about long-term code health",
          expertise: "Refactoring, testing, observability",
          goal: "Ensure the design is maintainable"
        }
      ]
    }
  end

  @doc "Red team template: Advocate + Adversary + User, round_robin, 6 rounds."
  @spec red_team(String.t(), String.t() | nil) :: map()
  def red_team(topic, context \\ nil) do
    %{
      topic: topic,
      context: context,
      strategy: :round_robin,
      max_rounds: 6,
      personas: [
        %{
          name: "Advocate",
          perspective: "Defends the proposal",
          expertise: "The proposed approach",
          goal: "Make the strongest case for the current plan"
        },
        %{
          name: "Adversary",
          perspective: "Attacks the proposal",
          expertise: "Failure modes, security, edge cases",
          goal: "Find every way this could go wrong"
        },
        %{
          name: "User",
          perspective: "End-user experience",
          expertise: "UX, accessibility, real-world usage",
          goal: "Ensure this actually serves users"
        }
      ]
    }
  end

  @doc "User panel template: Moderator + Power User + New User + Reluctant User, facilitator strategy, 8 rounds."
  @spec user_panel(String.t(), String.t() | nil) :: map()
  def user_panel(topic, context \\ nil) do
    %{
      topic: topic,
      context: context,
      strategy: :facilitator,
      facilitator: "Moderator",
      max_rounds: 8,
      personas: [
        %{
          name: "Moderator",
          perspective: "Neutral facilitator",
          expertise: "User research",
          goal: "Draw out honest reactions from the panel"
        },
        %{
          name: "Power User",
          perspective: "Uses the product daily, knows all shortcuts",
          expertise: "Deep product knowledge",
          goal: "Evaluate against advanced workflows"
        },
        %{
          name: "New User",
          perspective: "Just encountered the product",
          expertise: "Fresh eyes, no assumptions",
          goal: "Flag anything confusing or unintuitive"
        },
        %{
          name: "Reluctant User",
          perspective: "Prefers alternatives, skeptical",
          expertise: "Competitor products",
          goal: "Explain what would make them switch"
        }
      ]
    }
  end
end
