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
  alias Loomkin.Orchestration.Schema.CostEvent
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

  Returns a map with six keys:

    * `:pass_rate_by_gate`                — `%{gate_name => float | nil}`
    * `:iteration_distribution`           — `%{iteration => count}`
    * `:per_model_pass_rate`              — `%{model_string => float | nil}`
    * `:escalation_count`                 — non-negative integer
    * `:cost_per_epic`                    — `%{epic_id => Decimal.t()}` summed
      across `orchestration_cost_events` rows
    * `:avg_phase_duration_ms_by_phase`   — `%{phase_string => integer()}`,
      mean duration_ms for `:phase_entered` rows with a recorded duration

  A pass-rate of `nil` means no qualifying rows were observed.
  """
  @spec aggregate(filters()) :: %{
          pass_rate_by_gate: %{optional(String.t()) => float() | nil},
          iteration_distribution: %{optional(integer()) => integer()},
          per_model_pass_rate: %{optional(String.t()) => float() | nil},
          escalation_count: non_neg_integer(),
          cost_per_epic: %{optional(String.t()) => Decimal.t()},
          avg_phase_duration_ms_by_phase: %{optional(String.t()) => integer()}
        }
  def aggregate(filters \\ %{}) do
    normalized = normalize(filters)
    base = apply_filters(PhaseMetric, normalized)

    %{
      pass_rate_by_gate: pass_rate_by(base, :gate),
      iteration_distribution: iteration_distribution(base),
      per_model_pass_rate: pass_rate_by(base, :model),
      escalation_count: escalation_count(base),
      cost_per_epic: cost_per_epic(normalized),
      avg_phase_duration_ms_by_phase: avg_phase_duration_by_phase(base)
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

  # Sums `cost_usd` per epic from `orchestration_cost_events`. Honors the
  # `:epic_id` and `:since` filters (mirrors the PhaseMetric semantics) so the
  # dashboard windows line up. Rows with `cost_usd = nil` (unpriced model)
  # contribute 0 — the sum still includes them for tokens but not dollars.
  defp cost_per_epic(filters) do
    CostEvent
    |> apply_cost_filters(filters)
    |> where([c], not is_nil(c.epic_id))
    |> group_by([c], c.epic_id)
    |> select([c], {c.epic_id, sum(c.cost_usd)})
    |> Repo.all()
    |> Enum.reject(fn {_id, sum} -> is_nil(sum) end)
    |> Map.new()
  end

  defp apply_cost_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:epic_id, value}, q when not is_nil(value) ->
        where(q, [c], c.epic_id == ^value)

      {:since, %DateTime{} = since}, q ->
        where(q, [c], c.inserted_at >= ^since)

      _, q ->
        q
    end)
  end

  # Mean `duration_ms` of `:phase_entered` rows per phase string. Phases
  # without a duration recorded are excluded (the PhaseMetric column is
  # nullable). The result is rounded to integer milliseconds so the UI can
  # safely format with `div/2`.
  defp avg_phase_duration_by_phase(base) do
    base
    |> where([m], m.event_kind == :phase_entered)
    |> where([m], not is_nil(m.duration_ms))
    |> where([m], not is_nil(m.phase))
    |> group_by([m], m.phase)
    |> select([m], {m.phase, avg(m.duration_ms)})
    |> Repo.all()
    |> Enum.reject(fn {_p, avg} -> is_nil(avg) end)
    |> Enum.into(%{}, fn {phase, avg} -> {phase, round_avg(avg)} end)
  end

  defp round_avg(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp round_avg(n) when is_float(n), do: round(n)
  defp round_avg(n) when is_integer(n), do: n
  defp round_avg(_), do: 0

  @doc """
  ETA in milliseconds for an epic given its `current_phase`. Sums the
  `:avg_phase_duration_ms_by_phase` values for every phase that comes after
  `current_phase` in `Loomkin.Orchestration.phases/0`.

  Returns `nil` when there is no historical data for the remaining phases
  (so the UI can render an em-dash). When at least one downstream phase has
  data, missing phases are treated as zero — the dashboard explains this in
  its caption.
  """
  @spec eta_for_epic(String.t() | nil, atom() | String.t() | nil) :: integer() | nil
  def eta_for_epic(_epic_id, nil), do: nil

  def eta_for_epic(_epic_id, current_phase) do
    averages = avg_phase_duration_by_phase(PhaseMetric)
    phases = Loomkin.Orchestration.phases()
    cur_atom = to_phase_atom(current_phase)

    case Enum.find_index(phases, &(&1 == cur_atom)) do
      nil ->
        nil

      idx ->
        remaining = Enum.slice(phases, (idx + 1)..-1//1)

        sums =
          for p <- remaining,
              ms = Map.get(averages, Atom.to_string(p)),
              is_integer(ms) and ms > 0,
              do: ms

        case sums do
          [] -> nil
          ms_list -> Enum.sum(ms_list)
        end
    end
  end

  @doc """
  Total `cost_usd` for one epic across all `orchestration_cost_events` rows.
  Returns a `Decimal.t()` (possibly zero) or `nil` when no rows exist.
  """
  @spec cost_for_epic(String.t()) :: Decimal.t() | nil
  def cost_for_epic(epic_id) when is_binary(epic_id) do
    sum =
      CostEvent
      |> where([c], c.epic_id == ^epic_id)
      |> select([c], sum(c.cost_usd))
      |> Repo.one()

    sum
  end

  def cost_for_epic(_), do: nil

  defp to_phase_atom(phase) when is_atom(phase), do: phase

  defp to_phase_atom(phase) when is_binary(phase) do
    String.to_existing_atom(phase)
  rescue
    _ -> nil
  end

  defp to_phase_atom(_), do: nil

  # ----------------------------------------------------------------- helpers

  defp ensure_id(%{id: id} = attrs) when is_binary(id), do: attrs
  defp ensure_id(%{"id" => id} = attrs) when is_binary(id), do: attrs
  defp ensure_id(attrs), do: Map.put(attrs, :id, UUID.generate())
end
