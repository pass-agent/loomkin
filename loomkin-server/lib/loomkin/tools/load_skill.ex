defmodule Loomkin.Tools.LoadSkill do
  @moduledoc """
  Loads the full instructions for a named skill.
  Agents call this when they need detailed guidance from a skill they see in their manifest.
  """
  use Jido.Action,
    name: "load_skill",
    description:
      "Load the full instructions for a named skill. Use this when you see a relevant skill in your available skills list and need its detailed guidance for your current task.",
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "The skill name from the available skills list (e.g. 'elixir-expert')"
      ]
    ]

  @impl true
  def run(%{name: name}, _context) do
    case Loomkin.Skills.Resolver.get_body(name) do
      {:ok, body} -> {:ok, %{result: body}}
      {:error, :not_found} -> {:error, "Skill '#{name}' not found. Check available skills list."}
    end
  end
end
