defmodule Loomkin.Conversations.TemplatesTest do
  use ExUnit.Case, async: true

  alias Loomkin.Conversations.Templates

  @required_persona_fields [:name, :perspective, :expertise, :goal]

  describe "list/0" do
    test "returns all template names" do
      names = Templates.list()
      assert "brainstorm" in names
      assert "design_review" in names
      assert "red_team" in names
      assert "user_panel" in names
      assert length(names) == 4
    end
  end

  describe "get/3" do
    test "returns config for valid template" do
      assert {:ok, config} = Templates.get("brainstorm", "test topic")
      assert config.topic == "test topic"
      assert is_list(config.personas)
    end

    test "passes context through" do
      assert {:ok, config} = Templates.get("red_team", "topic", "some context")
      assert config.context == "some context"
    end

    test "returns error for unknown template" do
      assert {:error, msg} = Templates.get("nonexistent", "topic")
      assert msg =~ "Unknown template"
      assert msg =~ "brainstorm"
    end
  end

  describe "brainstorm/2" do
    test "returns valid config with 3 personas" do
      config = Templates.brainstorm("How to improve onboarding")
      assert config.topic == "How to improve onboarding"
      assert config.context == nil
      assert config.strategy == :round_robin
      assert config.max_rounds == 8
      assert length(config.personas) == 3
      assert_personas_valid(config.personas)
    end

    test "passes context" do
      config = Templates.brainstorm("topic", "extra context")
      assert config.context == "extra context"
    end

    test "includes Innovator, Pragmatist, and Critic" do
      names = Templates.brainstorm("topic") |> persona_names()
      assert "Innovator" in names
      assert "Pragmatist" in names
      assert "Critic" in names
    end
  end

  describe "design_review/2" do
    test "returns valid config with facilitator strategy" do
      config = Templates.design_review("API design review")
      assert config.topic == "API design review"
      assert config.strategy == :facilitator
      assert config.facilitator == "Tech Lead"
      assert config.max_rounds == 6
      assert length(config.personas) == 3
      assert_personas_valid(config.personas)
    end

    test "facilitator is one of the personas" do
      config = Templates.design_review("topic")
      names = persona_names(config)
      assert config.facilitator in names
    end

    test "includes Tech Lead, Domain Expert, and Maintainer" do
      names = Templates.design_review("topic") |> persona_names()
      assert "Tech Lead" in names
      assert "Domain Expert" in names
      assert "Maintainer" in names
    end
  end

  describe "red_team/2" do
    test "returns valid config with 3 personas" do
      config = Templates.red_team("Security approach")
      assert config.topic == "Security approach"
      assert config.strategy == :round_robin
      assert config.max_rounds == 6
      assert length(config.personas) == 3
      assert_personas_valid(config.personas)
    end

    test "includes Advocate, Adversary, and User" do
      names = Templates.red_team("topic") |> persona_names()
      assert "Advocate" in names
      assert "Adversary" in names
      assert "User" in names
    end
  end

  describe "user_panel/2" do
    test "returns valid config with 4 personas and facilitator" do
      config = Templates.user_panel("New dashboard feedback")
      assert config.topic == "New dashboard feedback"
      assert config.strategy == :facilitator
      assert config.facilitator == "Moderator"
      assert config.max_rounds == 8
      assert length(config.personas) == 4
      assert_personas_valid(config.personas)
    end

    test "facilitator is one of the personas" do
      config = Templates.user_panel("topic")
      names = persona_names(config)
      assert config.facilitator in names
    end

    test "includes Moderator, Power User, New User, and Reluctant User" do
      names = Templates.user_panel("topic") |> persona_names()
      assert "Moderator" in names
      assert "Power User" in names
      assert "New User" in names
      assert "Reluctant User" in names
    end
  end

  describe "all templates" do
    test "every template has between 2 and 6 personas" do
      for name <- Templates.list() do
        {:ok, config} = Templates.get(name, "test")
        count = length(config.personas)

        assert count >= 2 and count <= 6,
               "Template #{name} has #{count} personas, expected 2-6"
      end
    end

    test "every template has a strategy" do
      for name <- Templates.list() do
        {:ok, config} = Templates.get(name, "test")
        assert config.strategy in [:round_robin, :facilitator, :weighted]
      end
    end

    test "facilitator templates include facilitator field" do
      for name <- Templates.list() do
        {:ok, config} = Templates.get(name, "test")

        if config.strategy == :facilitator do
          assert Map.has_key?(config, :facilitator),
                 "Template #{name} uses facilitator strategy but has no facilitator field"

          names = persona_names(config)

          assert config.facilitator in names,
                 "Template #{name} facilitator '#{config.facilitator}' is not a persona"
        end
      end
    end

    test "all personas have unique names within each template" do
      for name <- Templates.list() do
        {:ok, config} = Templates.get(name, "test")
        names = persona_names(config)
        assert length(names) == length(Enum.uniq(names)), "Duplicate persona names in #{name}"
      end
    end
  end

  defp persona_names(config) when is_map(config), do: Enum.map(config.personas, & &1.name)

  defp assert_personas_valid(personas) do
    for persona <- personas do
      for field <- @required_persona_fields do
        assert Map.has_key?(persona, field),
               "Persona #{inspect(persona[:name])} missing required field #{field}"

        assert is_binary(Map.get(persona, field)),
               "Persona #{inspect(persona[:name])} field #{field} must be a string"
      end
    end
  end
end
