defmodule Loomkin.Signals.Complexity do
  @moduledoc "Complexity monitoring and adaptive spawning signals."

  defmodule ThresholdReached do
    use Jido.Signal,
      type: "team.complexity.threshold_reached",
      schema: [
        team_id: [type: :string, required: true],
        complexity_score: [type: :integer, required: true]
      ]
  end

  defmodule SpawnSuggested do
    use Jido.Signal,
      type: "team.spawn.suggested",
      schema: [
        team_id: [type: :string, required: true],
        specialist_type: [type: :string, required: true],
        reason: [type: :string, required: true],
        complexity_score: [type: :integer, required: true]
      ]
  end
end
