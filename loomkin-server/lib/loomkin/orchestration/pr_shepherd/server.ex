defmodule Loomkin.Orchestration.PRShepherd.Server do
  @moduledoc """
  Per-PR shepherd GenServer.

  Polls `GitHubClient.get_pr_status/1` on a fixed interval and transitions
  through a small state machine:

      :monitoring → :ready              (CI green + threads resolved)
      :monitoring → :comments_pending   (CI ok but unresolved actionable comments)
      :monitoring → :failed             (CI red OR client error)

  Terminal states (`:ready`, `:failed`) halt polling. `:comments_pending`
  keeps polling (the next poll might flip to `:ready` once comments are
  resolved, or `:failed` if CI flips red).

  Errors from the GitHub client are caught and converted to `:failed` — the
  GenServer never crashes on a bad API response. Internal exceptions are
  also rescued and shut the shepherd down cleanly.

  Broadcasts on the `"orchestration.pr_shepherd"` PubSub topic in the shape
  `{:pr_shepherd, pr_ref, state, meta}` where `meta` is a small map.
  """
  use GenServer

  alias Loomkin.Orchestration.PRShepherd.GitHubClient

  @topic "orchestration.pr_shepherd"
  @default_poll_ms 30_000

  @typedoc "PR identifier: {owner, repo, pr_number}."
  @type pr_ref :: {String.t(), String.t(), pos_integer()}

  @typedoc "Shepherd state observed externally."
  @type state :: :monitoring | :comments_pending | :ready | :failed | :stopped

  ## ─── Public API ────────────────────────────────────────────────────────

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :pr_ref)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    pr_ref = Keyword.fetch!(opts, :pr_ref)
    name = via(pr_ref)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Return the shepherd's current snapshot."
  def status(pid_or_via) do
    GenServer.call(resolve(pid_or_via), :status)
  end

  @doc "Stop the shepherd. Cancels any pending poll timer."
  def stop(pid_or_via, reason \\ :normal) do
    GenServer.stop(resolve(pid_or_via), reason)
  end

  @doc "Resolve a `pr_ref` or pid into a callable target. Public for LiveView."
  def resolve(pid) when is_pid(pid), do: pid
  def resolve({:via, _, _} = via), do: via
  def resolve({_, _, _} = pr_ref), do: via(pr_ref)

  @doc "Look up the registered shepherd pid for a PR ref, if any."
  def whereis({_, _, _} = pr_ref) do
    case Registry.lookup(Loomkin.Orchestration.ShepherdRegistry, pr_ref) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(pr_ref),
    do: {:via, Registry, {Loomkin.Orchestration.ShepherdRegistry, pr_ref}}

  ## ─── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    pr_ref = Keyword.fetch!(opts, :pr_ref)

    state = %{
      pr_ref: pr_ref,
      epic_id: Keyword.get(opts, :epic_id),
      client: Keyword.get(opts, :github_client, GitHubClient.impl()),
      poll_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_ms),
      shepherd_state: :monitoring,
      last_ci: nil,
      last_comments: [],
      last_reason: nil,
      poll_ref: nil,
      polls: 0
    }

    {:ok, schedule_poll(state, 0)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, snapshot(state), state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | poll_ref: nil, polls: state.polls + 1}

    case safe_get_status(state.client, state.pr_ref) do
      {:ok, %{ci: ci, comments: comments}} ->
        handle_status(state, ci, comments)

      {:error, reason} ->
        transition_failed(state, {:client_error, reason})
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.poll_ref)
    :ok
  end

  ## ─── Internals ─────────────────────────────────────────────────────────

  defp handle_status(state, :failure, comments) do
    state = %{state | last_ci: :failure, last_comments: comments}
    transition_failed(state, :ci_failure)
  end

  defp handle_status(state, :success, comments) do
    actionable = unresolved_actionable(comments)
    state = %{state | last_ci: :success, last_comments: comments}

    if actionable == [] do
      transition_ready(state)
    else
      transition_comments_pending(state, actionable)
    end
  end

  defp handle_status(state, ci, comments) do
    # :pending or anything else — keep monitoring.
    state = %{state | last_ci: ci, last_comments: comments, shepherd_state: :monitoring}
    {:noreply, schedule_poll(state)}
  end

  defp transition_ready(state) do
    state = %{state | shepherd_state: :ready, last_reason: nil}
    broadcast(state, :ready, %{})
    {:noreply, %{state | poll_ref: nil}}
  end

  defp transition_failed(state, reason) do
    state = %{state | shepherd_state: :failed, last_reason: reason}
    broadcast(state, :failed, %{reason: reason})
    {:noreply, %{state | poll_ref: nil}}
  end

  defp transition_comments_pending(state, actionable) do
    state = %{state | shepherd_state: :comments_pending, last_reason: nil}

    broadcast(state, :comments_pending, %{
      count: length(actionable),
      ids: Enum.map(actionable, & &1[:id])
    })

    {:noreply, schedule_poll(state)}
  end

  defp unresolved_actionable(comments) when is_list(comments) do
    Enum.filter(comments, fn
      %{resolved: true} -> false
      %{} = c -> actionable?(c)
      _ -> false
    end)
  end

  defp unresolved_actionable(_), do: []

  # Heuristic: every unresolved review comment is actionable in v1. A future
  # iteration can filter on body keywords or author roles.
  defp actionable?(_comment), do: true

  defp safe_get_status(client, pr_ref) do
    client.get_pr_status(pr_ref)
  rescue
    e -> {:error, {:exception, e}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp schedule_poll(state, override_ms \\ nil) do
    cancel_timer(state.poll_ref)
    delay = override_ms || state.poll_ms
    ref = Process.send_after(self(), :poll, delay)
    %{state | poll_ref: ref}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp broadcast(state, status, meta) do
    payload = {:pr_shepherd, state.pr_ref, status, Map.put(meta, :epic_id, state.epic_id)}

    case Process.whereis(Loomkin.PubSub) do
      nil -> :ok
      _ -> Phoenix.PubSub.broadcast(Loomkin.PubSub, @topic, payload)
    end

    :telemetry.execute(
      [:loomkin, :orchestration, :pr_shepherd, :transition],
      %{count: 1},
      %{pr_ref: state.pr_ref, epic_id: state.epic_id, status: status}
    )
  rescue
    _ -> :ok
  end

  defp snapshot(state) do
    %{
      state: state.shepherd_state,
      pr_ref: state.pr_ref,
      epic_id: state.epic_id,
      ci: state.last_ci,
      comment_count: length(state.last_comments),
      unresolved_count: length(unresolved_actionable(state.last_comments)),
      reason: state.last_reason,
      polls: state.polls
    }
  end

  @doc "PubSub topic shepherds publish to."
  def topic, do: @topic
end
