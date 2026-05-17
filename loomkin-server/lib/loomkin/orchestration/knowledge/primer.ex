defmodule Loomkin.Orchestration.Knowledge.Primer do
  @moduledoc """
  Loomkin's equivalent of `bd prime`.

  Ranks knowledge facts by `recency × confidence × tag_overlap` so the
  orchestrator can pre-load the most relevant facts into a worker's system
  prompt before a phase runs.

  Pure function over the in-memory list — callers may either pass a list
  directly (preferred when you've already loaded a subset) or omit it to
  load via `KnowledgeStore.list_facts/1` first.
  """

  alias Loomkin.Orchestration.KnowledgeStore
  alias Loomkin.Orchestration.Schema.KnowledgeFact

  @recency_half_life_days 30
  @confidence_weight %{high: 1.0, medium: 0.7, low: 0.4}

  @doc """
  Returns the top-N facts most relevant to the given context.

  Options:

    * `:keywords` — list of strings; matched against fact tags case-insensitively
    * `:work_type` — atom hint; used as an additional tag (e.g. `:planning`)
    * `:affected_files` — list of file paths; matched against `affected_files`
    * `:limit` — max number to return (default 10)
    * `:facts` — pre-loaded fact list; if omitted, queried via KnowledgeStore
    * `:now` — DateTime used as "now" for recency decay (default `DateTime.utc_now`)
  """
  @spec prime(keyword()) :: [KnowledgeFact.t()]
  def prime(opts \\ []) do
    facts = Keyword.get_lazy(opts, :facts, fn -> KnowledgeStore.list_facts(%{}) end)
    keywords = opts |> Keyword.get(:keywords, []) |> Enum.map(&String.downcase/1)
    work_type = Keyword.get(opts, :work_type)
    files = Keyword.get(opts, :affected_files, [])
    limit = Keyword.get(opts, :limit, 10)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    facts
    |> Enum.map(&{score(&1, keywords, work_type, files, now), &1})
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_, fact} -> fact end)
  end

  @doc "Exposed for inspection / tests."
  @spec score(KnowledgeFact.t(), [String.t()], atom() | nil, [String.t()], DateTime.t()) ::
          float()
  def score(%KnowledgeFact{} = fact, keywords, work_type, files, now) do
    recency_decay(fact, now) * confidence_weight(fact) *
      relevance(fact, keywords, work_type, files)
  end

  defp recency_decay(%KnowledgeFact{inserted_at: nil}, _now), do: 0.5

  defp recency_decay(%KnowledgeFact{inserted_at: at}, now) do
    seconds = DateTime.diff(now, at)
    days = max(seconds, 0) / 86_400
    :math.pow(0.5, days / @recency_half_life_days)
  end

  defp confidence_weight(%KnowledgeFact{confidence: c}) do
    Map.get(@confidence_weight, c, 0.5)
  end

  defp relevance(%KnowledgeFact{tags: tags, affected_files: af}, keywords, work_type, files) do
    tag_set = MapSet.new((tags || []) |> Enum.map(&String.downcase/1))
    kw_match = if keywords == [], do: 1.0, else: overlap(tag_set, keywords)

    type_match =
      if is_nil(work_type),
        do: 1.0,
        else: if(MapSet.member?(tag_set, Atom.to_string(work_type)), do: 1.2, else: 1.0)

    file_match =
      if files == [] or af in [nil, []], do: 1.0, else: overlap(MapSet.new(af), files) + 1.0

    kw_match * type_match * file_match
  end

  defp overlap(_, []), do: 1.0

  defp overlap(set, needles) do
    matched =
      Enum.count(needles, fn n ->
        MapSet.member?(set, n) or
          Enum.any?(set, &String.contains?(&1, n))
      end)

    1.0 + matched / max(length(needles), 1)
  end
end
