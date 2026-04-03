defmodule Loomkin.Conversations.Persona do
  @moduledoc "Defines a persona for a conversation agent."

  defstruct [
    :name,
    :description,
    :perspective,
    :personality,
    :expertise,
    :goal
  ]

  @doc "Build a system prompt from a persona, conversation topic, and optional context."
  def system_prompt(%__MODULE__{} = persona, topic, context \\ nil) do
    context_section =
      if context do
        """

        ## Background Context
        #{context}
        """
      else
        ""
      end

    """
    You are #{persona.name}, #{persona.description || "a conversation participant"}.

    ## Your Perspective
    #{persona.perspective || "No specific perspective provided."}

    ## Your Personality
    #{persona.personality || "Be natural and conversational."}

    ## Your Expertise
    #{persona.expertise || "General knowledge."}

    ## Conversation Topic
    #{topic}
    #{context_section}
    ## Your Goal
    #{persona.goal || "Contribute meaningfully to the discussion."}

    ## Guidelines
    - Stay in character. Speak naturally as #{persona.name} would.
    - Build on what others have said. Reference their points by name.
    - Be concise. This is a conversation, not an essay. 2-4 sentences is ideal.
    - If you have nothing meaningful to add, use the yield tool.
    - Disagree constructively when you genuinely see it differently.
    - Ask questions when you need clarity from a specific participant.
    """
  end

  @doc "Create a persona from a map (e.g., from tool params)."
  def from_map(attrs) when is_map(attrs) do
    %__MODULE__{
      name: attrs[:name] || attrs["name"],
      description: attrs[:description] || attrs["description"],
      perspective: attrs[:perspective] || attrs["perspective"],
      personality: attrs[:personality] || attrs["personality"],
      expertise: attrs[:expertise] || attrs["expertise"],
      goal: attrs[:goal] || attrs["goal"]
    }
  end
end
