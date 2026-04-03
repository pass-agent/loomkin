defmodule Loomkin.Vault.Validators.TemporalLanguage do
  @moduledoc """
  Validates that evergreen vault entries do not contain temporal language.
  Returns :ok or {:warn, violations} — never blocks writes.
  """

  # Temporal types (spec, milestone, decision, meeting, checkin, okr) are intentionally
  # excluded — they describe planned/time-bound work and use temporal language by design.
  @evergreen_types ~w(note topic project person idea source stream_idea guest_profile)

  @blocked_patterns [
    {~r/\bwill\b/i, "will", "Use present tense or move to a decision record"},
    {~r/\bgoing to\b/i, "going to", "Use present tense"},
    {~r/\brecently\b/i, "recently", "Remove or state the current situation"},
    {~r/\bsoon\b/i, "soon", "Remove or move to a decision/meeting record"},
    {~r/\bcurrently\b/i, "currently", "Remove — just state the fact"},
    {~r/\bnext (week|month|quarter|year)\b/i, "next [time]", "Move to a temporal record"},
    {~r/\bpreviously\b/i, "previously", "State the current situation instead"},
    {~r/\bplanned\b/i, "planned", "Move to a decision record or remove"},
    {~r/\bwas\b/i, "was", "Use present tense — describe what IS, not what WAS"}
  ]

  @doc """
  Validate an entry map for temporal language.
  Returns :ok or {:warn, [violation]} where each violation is a map with
  :path, :line, :word, and :suggestion keys.
  """
  @spec validate(map()) :: :ok | {:warn, [map()]}
  def validate(%{entry_type: type, body: body, path: path})
      when type in @evergreen_types and is_binary(body) do
    violations =
      @blocked_patterns
      |> Enum.flat_map(fn {regex, word, fix} ->
        case Regex.scan(regex, body, return: :index) do
          [] ->
            []

          matches ->
            Enum.map(matches, fn [{pos, _len} | _] ->
              line = body |> String.slice(0, pos) |> String.split("\n") |> length()
              %{path: path, line: line, word: word, suggestion: fix}
            end)
        end
      end)

    case violations do
      [] -> :ok
      vs -> {:warn, vs}
    end
  end

  def validate(_entry), do: :ok
end
