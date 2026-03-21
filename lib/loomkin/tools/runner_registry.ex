defmodule Loomkin.Tools.RunnerRegistry do
  @moduledoc """
  Tracks and limits concurrent tool executions by type.

  Each tool execution must acquire a slot before running and release it
  after completion. When per-type or total limits are reached, acquire
  returns `{:error, :concurrency_limit}` — the caller can retry later.

  ## Configuration

      config :loomkin, :runner_limits,
        shell: 20,
        file_write: 10,
        file_edit: 10,
        default: 10,
        total: 50
  """

  use GenServer

  require Logger

  # -- Public API --

  @doc "Starts the RunnerRegistry as a named GenServer."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquires a concurrency slot for the given tool type.

  Returns `:ok` on success or `{:error, :concurrency_limit}` when
  the per-type or total limit has been reached.
  """
  @spec acquire(atom(), GenServer.server()) :: :ok | {:error, :concurrency_limit}
  def acquire(tool_type, server \\ __MODULE__) do
    GenServer.call(server, {:acquire, tool_type, self()})
  end

  @doc """
  Releases a concurrency slot for the given tool type.

  Returns `:ok`. Releasing a slot that was never acquired is a no-op.
  """
  @spec release(atom(), GenServer.server()) :: :ok
  def release(tool_type, server \\ __MODULE__) do
    GenServer.call(server, {:release, tool_type, self()})
  end

  @doc """
  Returns a snapshot of current counts: `%{by_type: %{shell: 3, ...}, total: 5}`.
  """
  @spec status(GenServer.server()) :: %{by_type: map(), total: non_neg_integer()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Wraps a function with acquire/release, returning `{:error, :concurrency_limit}`
  if the slot cannot be acquired, or the function's return value otherwise.
  """
  @spec with_limit(atom(), GenServer.server(), (-> result)) ::
          {:error, :concurrency_limit} | result
        when result: var
  def with_limit(tool_type, server \\ __MODULE__, fun) do
    case acquire(tool_type, server) do
      :ok ->
        try do
          fun.()
        after
          release(tool_type, server)
        end

      {:error, :concurrency_limit} = err ->
        err
    end
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    limits = Keyword.get(opts, :limits) || configured_limits()

    state = %{
      counts: %{},
      monitors: %{},
      limits: limits
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, tool_type, pid}, _from, state) do
    limits = state.limits
    type_count = Map.get(state.counts, tool_type, 0)
    total_count = total(state.counts)
    type_limit = Map.get(limits, tool_type) || Map.get(limits, :default, 10)
    total_limit = Map.get(limits, :total, 50)

    if type_count < type_limit and total_count < total_limit do
      new_counts = Map.update(state.counts, tool_type, 1, &(&1 + 1))
      new_monitors = monitor_pid(state.monitors, pid, tool_type)

      :telemetry.execute(
        [:loomkin, :runner, :acquired],
        %{count: type_count + 1, total: total_count + 1},
        %{tool_type: tool_type}
      )

      {:reply, :ok, %{state | counts: new_counts, monitors: new_monitors}}
    else
      :telemetry.execute(
        [:loomkin, :runner, :rejected],
        %{count: type_count, total: total_count},
        %{tool_type: tool_type, reason: :concurrency_limit}
      )

      {:reply, {:error, :concurrency_limit}, state}
    end
  end

  def handle_call({:release, tool_type, pid}, _from, state) do
    {new_counts, new_monitors} = do_release(state.counts, state.monitors, tool_type, pid)

    type_count = Map.get(new_counts, tool_type, 0)
    total_count = total(new_counts)

    :telemetry.execute(
      [:loomkin, :runner, :released],
      %{count: type_count, total: total_count},
      %{tool_type: tool_type}
    )

    {:reply, :ok, %{state | counts: new_counts, monitors: new_monitors}}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{by_type: state.counts, total: total(state.counts)}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{^pid, tool_type}, new_monitors} ->
        new_counts = decrement(state.counts, tool_type)

        Logger.debug("[RunnerRegistry] process #{inspect(pid)} died, released #{tool_type} slot")

        {:noreply, %{state | counts: new_counts, monitors: new_monitors}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Internal helpers --

  defp configured_limits do
    Application.get_env(:loomkin, :runner_limits, %{})
    |> Map.new()
  end

  defp total(counts) do
    counts |> Map.values() |> Enum.sum()
  end

  defp monitor_pid(monitors, pid, tool_type) do
    ref = Process.monitor(pid)
    Map.put(monitors, ref, {pid, tool_type})
  end

  defp do_release(counts, monitors, tool_type, pid) do
    new_counts = decrement(counts, tool_type)

    # Find and remove the monitor for this pid+tool_type (first match)
    case Enum.find(monitors, fn {_ref, {p, tt}} -> p == pid and tt == tool_type end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        {new_counts, Map.delete(monitors, ref)}

      nil ->
        {new_counts, monitors}
    end
  end

  defp decrement(counts, tool_type) do
    case Map.get(counts, tool_type, 0) do
      n when n <= 1 -> Map.delete(counts, tool_type)
      n -> Map.put(counts, tool_type, n - 1)
    end
  end
end
