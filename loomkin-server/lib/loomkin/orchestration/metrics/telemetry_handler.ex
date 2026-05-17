defmodule Loomkin.Orchestration.Metrics.TelemetryHandler do
  @moduledoc """
  Attaches `:telemetry` handlers for orchestration events and persists them
  via `Loomkin.Orchestration.Metrics.record/1`.

  Events captured:

    * `[:loomkin, :orchestration, :epic, :phase_entered]`     -> `:phase_entered`
    * `[:loomkin, :orchestration, :gate, :verdict]`           -> `:gate_verdict`
    * `[:loomkin, :orchestration, :epic, :escalated]`         -> `:escalated`
    * `[:loomkin, :orchestration, :work_unit, :completed]`    -> `:work_unit_completed`
    * `[:loomkin, :orchestration, :work_unit, :failed]`       -> `:work_unit_failed`

  Telemetry handlers are run synchronously in the emitting process, so this
  module never raises -- a failed insert is logged and swallowed. In
  particular:

    * `Loomkin.Repo` may not yet be running during early boot (silently no-op),
    * test processes may emit events without first allowing the handler PID
      through the Ecto SQL Sandbox (those inserts will fail loudly inside
      `Repo.insert/1` and we suppress the resulting `DBConnection` /
      `Ecto.Adapters.SQL.Sandbox` errors so async test pollution doesn't
      cascade into unrelated assertions).
  """
  use GenServer

  require Logger

  alias Loomkin.Orchestration.Metrics

  @handler_id "loomkin-orchestration-metrics-telemetry-handler"

  @events [
    [:loomkin, :orchestration, :epic, :phase_entered],
    [:loomkin, :orchestration, :gate, :verdict],
    [:loomkin, :orchestration, :epic, :escalated],
    [:loomkin, :orchestration, :work_unit, :completed],
    [:loomkin, :orchestration, :work_unit, :failed]
  ]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the list of telemetry event names this handler subscribes to."
  def events, do: @events

  @doc "Returns the handler id used for `:telemetry.attach_many/4`."
  def handler_id, do: @handler_id

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    # Defensive detach in case a previous run left the id behind (test reloads,
    # `Application.stop/start`, etc.). `:telemetry.detach/1` is a no-op when the
    # id is not currently attached.
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
  Routes a telemetry event to a `Metrics.record/1` call.

  Always returns `:ok` -- telemetry handlers must never raise.
  """
  def handle_event(event, measurements, metadata, _config) do
    attrs = build_attrs(event, measurements, metadata)
    persist(attrs)
    :ok
  rescue
    error ->
      Logger.debug(fn ->
        "TelemetryHandler swallowed #{inspect(error.__struct__)}: #{Exception.message(error)}"
      end)

      :ok
  catch
    kind, reason ->
      Logger.debug(fn ->
        "TelemetryHandler swallowed #{kind}: #{inspect(reason)}"
      end)

      :ok
  end

  ## Internals

  defp build_attrs(
         [:loomkin, :orchestration, :epic, :phase_entered],
         measurements,
         metadata
       ) do
    %{
      event_kind: :phase_entered,
      epic_id: fetch_id(metadata, :epic_id),
      phase: stringify(metadata[:phase]),
      duration_ms: fetch_duration(measurements),
      metadata: knob_metadata(metadata)
    }
  end

  defp build_attrs(
         [:loomkin, :orchestration, :gate, :verdict],
         measurements,
         metadata
       ) do
    %{
      event_kind: :gate_verdict,
      epic_id: fetch_id(metadata, :epic_id),
      gate: stringify(metadata[:gate]),
      verdict: normalize_verdict(metadata[:verdict]),
      iteration: metadata[:iteration] || 1,
      duration_ms: fetch_duration(measurements),
      model: stringify(metadata[:model])
    }
  end

  defp build_attrs(
         [:loomkin, :orchestration, :epic, :escalated],
         _measurements,
         metadata
       ) do
    %{
      event_kind: :escalated,
      epic_id: fetch_id(metadata, :epic_id),
      metadata: escalation_metadata(metadata)
    }
  end

  defp build_attrs(
         [:loomkin, :orchestration, :work_unit, :completed],
         measurements,
         metadata
       ) do
    %{
      event_kind: :work_unit_completed,
      epic_id: fetch_id(metadata, :epic_id),
      work_unit_id: fetch_id(metadata, :work_unit_id),
      duration_ms: fetch_duration(measurements)
    }
  end

  defp build_attrs(
         [:loomkin, :orchestration, :work_unit, :failed],
         measurements,
         metadata
       ) do
    %{
      event_kind: :work_unit_failed,
      epic_id: fetch_id(metadata, :epic_id),
      work_unit_id: fetch_id(metadata, :work_unit_id),
      duration_ms: fetch_duration(measurements)
    }
  end

  defp persist(attrs) do
    # The Repo may not be running during application boot, or the calling
    # process (in tests) may not own a sandbox checkout. Either way: telemetry
    # handlers MUST NOT raise, so we swallow everything with a debug log.
    case Process.whereis(Loomkin.Repo) do
      nil ->
        :ok

      _pid ->
        case Metrics.record(attrs) do
          {:ok, _metric} ->
            :ok

          {:error, changeset} ->
            Logger.debug(fn ->
              "TelemetryHandler dropped metric #{inspect(attrs.event_kind)}: " <>
                inspect(changeset.errors)
            end)

            :ok
        end
    end
  rescue
    error ->
      Logger.debug(fn ->
        "TelemetryHandler persist rescued #{inspect(error.__struct__)}: " <>
          Exception.message(error)
      end)

      :ok
  catch
    kind, reason ->
      Logger.debug(fn ->
        "TelemetryHandler persist caught #{kind}: #{inspect(reason)}"
      end)

      :ok
  end

  defp fetch_id(metadata, key) do
    case Map.get(metadata, key) do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp fetch_duration(%{duration_ms: ms}) when is_integer(ms) and ms >= 0, do: ms

  defp fetch_duration(%{duration: native}) when is_integer(native) and native >= 0 do
    System.convert_time_unit(native, :native, :millisecond)
  end

  defp fetch_duration(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)

  defp normalize_verdict(:pass), do: :pass
  defp normalize_verdict(:fail), do: :fail
  defp normalize_verdict("pass"), do: :pass
  defp normalize_verdict("fail"), do: :fail
  defp normalize_verdict(_), do: :unknown

  defp knob_metadata(%{attempt_knobs: knobs}) when is_map(knobs) do
    %{"attempt_knobs" => stringify_keys(knobs)}
  end

  defp knob_metadata(_), do: %{}

  defp escalation_metadata(%{iterations: iterations}) when is_map(iterations) do
    %{"iterations" => stringify_keys(iterations)}
  end

  defp escalation_metadata(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      {key, jsonable(v)}
    end
  end

  defp jsonable(v) when is_map(v), do: stringify_keys(v)
  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)

  defp jsonable(v) when is_atom(v) and not is_nil(v) and v not in [true, false],
    do: Atom.to_string(v)

  defp jsonable(v), do: v
end
