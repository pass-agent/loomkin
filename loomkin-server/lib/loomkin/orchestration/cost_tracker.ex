defmodule Loomkin.Orchestration.CostTracker do
  @moduledoc """
  Attributes ReqLLM token costs to the originating epic and persists
  per-call cost events.

  Attribution model: `Loomkin.Orchestration.LLM.ReqLLM` seeds
  `Process.put(:loomkin_epic_id, id)` from `opts[:epic_id]` before calling
  the provider, and emits a
  `[:loomkin, :orchestration, :llm, :request, :stop]` telemetry event after
  the call completes. This GenServer attaches to that event, looks up the
  epic_id (from meta or the process dict), prices the call via the static
  `PricingTable`, and inserts an `orchestration_cost_events` row.

  When no epic_id is in either place, the call is still recorded with
  `epic_id: nil` -- useful for global accounting and future backfill.

  When the model is not in the `PricingTable`, `cost_usd` is recorded as
  `nil` but the token counts are still persisted.

  Telemetry handlers run synchronously in the emitting process, so
  `handle_event/4` is defensive: it never raises, swallowing both
  exceptions and `:catch`-style throws/exits with a debug log.
  """
  use GenServer

  require Logger

  alias Loomkin.Orchestration.CostTracker.PricingTable
  alias Loomkin.Orchestration.Schema.CostEvent

  @handler_id "loomkin-orchestration-cost-tracker"
  @events [
    [:loomkin, :orchestration, :llm, :request, :stop]
  ]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the list of telemetry events this handler subscribes to."
  def events, do: @events

  @doc "Returns the handler id used for `:telemetry.attach_many/4`."
  def handler_id, do: @handler_id

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    # Defensive detach in case a previous run left the id behind.
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        @events,
        &__MODULE__.handle_event/4,
        %{}
      )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  ## Telemetry callback

  @doc """
  Persists a cost-event row from a telemetry emission.

  Never raises -- telemetry handlers must be defensive.
  """
  def handle_event(_event, measurements, meta, _config) do
    epic_id = meta[:epic_id] || Process.get(:loomkin_epic_id)
    model = stringify(meta[:model])
    in_t = to_non_neg_int(measurements[:input_tokens])
    out_t = to_non_neg_int(measurements[:output_tokens])
    cost = price(model, in_t, out_t)

    persist(%{
      epic_id: epic_id,
      model: model,
      input_tokens: in_t,
      output_tokens: out_t,
      cost_usd: cost
    })
  rescue
    error ->
      Logger.debug(fn ->
        "CostTracker swallowed #{inspect(error.__struct__)}: " <>
          Exception.message(error)
      end)

      :ok
  catch
    kind, reason ->
      Logger.debug(fn ->
        "CostTracker swallowed #{kind}: #{inspect(reason)}"
      end)

      :ok
  end

  ## Pricing

  @doc """
  Returns the `Decimal` cost in USD for a given model + token counts, or `nil`
  when the model is not priced. Public for testing.
  """
  @spec price(String.t() | nil, integer(), integer()) :: Decimal.t() | nil
  def price(model, in_t, out_t) when is_binary(model) do
    case PricingTable.lookup(model) do
      {:ok, %{input_per_1m: i, output_per_1m: o}} ->
        million = Decimal.new(1_000_000)

        input_cost = Decimal.div(Decimal.mult(Decimal.new(in_t), i), million)
        output_cost = Decimal.div(Decimal.mult(Decimal.new(out_t), o), million)

        Decimal.add(input_cost, output_cost)

      :error ->
        nil
    end
  end

  def price(_model, _in_t, _out_t), do: nil

  ## Internals

  defp persist(attrs) do
    case Process.whereis(Loomkin.Repo) do
      nil ->
        :ok

      _pid ->
        attrs = Map.put(attrs, :id, Ecto.UUID.generate())

        case %CostEvent{} |> CostEvent.changeset(attrs) |> Loomkin.Repo.insert() do
          {:ok, _row} ->
            :ok

          {:error, changeset} ->
            Logger.debug(fn ->
              "CostTracker dropped event: " <> inspect(changeset.errors)
            end)

            :ok
        end
    end
  rescue
    error ->
      Logger.debug(fn ->
        "CostTracker persist rescued #{inspect(error.__struct__)}: " <>
          Exception.message(error)
      end)

      :ok
  catch
    kind, reason ->
      Logger.debug(fn ->
        "CostTracker persist caught #{kind}: #{inspect(reason)}"
      end)

      :ok
  end

  defp to_non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp to_non_neg_int(_), do: 0

  defp stringify(nil), do: nil
  defp stringify(s) when is_binary(s), do: s
  defp stringify(a) when is_atom(a), do: Atom.to_string(a)
  defp stringify(other), do: to_string(other)
end
