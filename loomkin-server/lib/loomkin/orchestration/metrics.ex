defmodule Loomkin.Orchestration.Metrics do
  @moduledoc """
  Context module for orchestration phase metrics.

  Owns inserts, filtered reads, and roll-ups over
  `Loomkin.Orchestration.Schema.PhaseMetric`. The LiveView dashboard (round 2)
  is the primary consumer of `list/1` and `aggregate/1`. The telemetry
  handler (also round 2) is the primary producer feeding `record/1`.

  All filter maps accept string or atom keys.
  """

  import Ecto.Query, warn: false

  alias Ecto.UUID
  alias Loomkin.Orchestration.Schema.PhaseMetric
  alias Loomkin.Repo

  @type filters :: %{optional(atom() | String.t()) => term()}

  @doc """
  Insert a single phase-metric row.

  `attrs` may omit `:id` (one is generated). Returns the inserted struct or a
  changeset error tuple — we never silently drop a metric.
  """
  @spec record(map()) :: {:ok, PhaseMetric.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    attrs = ensure_id(attrs)

    %PhaseMetric{}
    |> PhaseMetric.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List phase-metric rows, optionally filtered.

  Supported filter keys:

    * `:epic_id`     — exact match on epic
    * `:event_kind`  — exact match on event kind (atom)
    * `:since`       — only rows with `inserted_at >= since` (`DateTime`)
  """
  @spec list(filters()) :: [PhaseMetric.t()]
  def list(filters \\ %{}) do
    PhaseMetric
    |> apply_filters(normalize(filters))
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  Aggregate phase-metric rows into dashboard-friendly summaries.

  Returns a map with four keys:

    * `:pass_rate_by_gate`     — `%{gate_name => float | nil}`
    * `:iteration_distribution`— `%{iteration => count}`
    * `:per_model_pass_rate`   — `%{model_string => float | nil}`
    * `:escalation_count`      — non-negative integer

  A pass-rate of `nil` means no qualifying rows were observed.
  """
  @spec aggregate(filters()) :: %{
          pass_rate_by_gate: %{optional(String.t()) => float() | nil},
          iteration_distribution: %{optional(integer()) => integer()},
          per_model_pass_rate: %{optional(String.t()) => float() | nil},
          escalation_count: non_neg_integer()
        }
  def aggregate(filters \\ %{}) do
    normalized = normalize(filters)
    base = apply_filters(PhaseMetric, normalized)

    %{
      pass_rate_by_gate: pass_rate_by(base, :gate),
      iteration_distribution: iteration_distribution(base),
      per_model_pass_rate: pass_rate_by(base, :model),
      escalation_count: escalation_count(base)
    }
  end

  # ------------------------------------------------------------------ filters

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:epic_id, value}, q when not is_nil(value) ->
        where(q, [m], m.epic_id == ^value)

      {:event_kind, value}, q when not is_nil(value) ->
        where(q, [m], m.event_kind == ^value)

      {:since, %DateTime{} = since}, q ->
        where(q, [m], m.inserted_at >= ^since)

      _, q ->
        q
    end)
  end

  defp normalize(filters) when is_map(filters) do
    for {k, v} <- filters, into: %{} do
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, v}
    end
  end

  # ----------------------------------------------------------- aggregations

  defp pass_rate_by(base, field) do
    rows =
      base
      |> where([m], m.event_kind == :gate_verdict)
      |> where([m], not is_nil(field(m, ^field)))
      |> where([m], m.verdict in [:pass, :fail])
      |> group_by([m], field(m, ^field))
      |> select([m], {
        field(m, ^field),
        count(m.id),
        fragment("count(*) FILTER (WHERE ? = 'pass')", m.verdict)
      })
      |> Repo.all()

    for {key, total, passes} <- rows, into: %{} do
      {key, pass_rate(passes, total)}
    end
  end

  defp iteration_distribution(base) do
    base
    |> where([m], m.event_kind == :gate_verdict)
    |> group_by([m], m.iteration)
    |> select([m], {m.iteration, count(m.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp escalation_count(base) do
    base
    |> where([m], m.event_kind == :escalated)
    |> select([m], count(m.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp pass_rate(_passes, 0), do: nil
  defp pass_rate(passes, total), do: passes / total

  # ----------------------------------------------------------------- helpers

  defp ensure_id(%{id: id} = attrs) when is_binary(id), do: attrs
  defp ensure_id(%{"id" => id} = attrs) when is_binary(id), do: attrs
  defp ensure_id(attrs), do: Map.put(attrs, :id, UUID.generate())
end
