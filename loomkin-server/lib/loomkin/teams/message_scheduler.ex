defmodule Loomkin.Teams.MessageScheduler do
  @moduledoc """
  Per-team GenServer that schedules messages for future delivery to agents.

  Uses `Process.send_after/3` to fire delivery at the scheduled time.
  If the target agent is busy, retries after 30 seconds.
  """

  use GenServer

  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.Manager

  @retry_delay_ms 30_000
  @max_retries 10

  defmodule ScheduledMessage do
    @moduledoc false

    @enforce_keys [:id, :content, :target_agent, :team_id, :deliver_at, :scheduled_at, :status]
    defstruct [
      :id,
      :content,
      :target_agent,
      :team_id,
      :deliver_at,
      :scheduled_at,
      :status,
      :timer_ref,
      :metadata,
      retry_count: 0
    ]
  end

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
  end

  @doc "Schedule a message for future delivery to an agent."
  @spec schedule(String.t(), String.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, ScheduledMessage.t()} | {:error, term()}
  def schedule(team_id, content, target_agent, deliver_at, opts \\ []) do
    GenServer.call(via(team_id), {:schedule, content, target_agent, deliver_at, opts})
  end

  @doc "Cancel a scheduled message."
  @spec cancel(String.t(), String.t()) :: :ok | {:error, :not_found}
  def cancel(team_id, message_id) do
    GenServer.call(via(team_id), {:cancel, message_id})
  end

  @doc "Edit a scheduled message's content and/or delivery time."
  @spec edit(String.t(), String.t(), map()) ::
          {:ok, ScheduledMessage.t()} | {:error, term()}
  def edit(team_id, message_id, changes) do
    GenServer.call(via(team_id), {:edit, message_id, changes})
  end

  @doc "List scheduled messages. Pass `status: :all` to include non-pending."
  @spec list(String.t(), keyword()) :: [ScheduledMessage.t()]
  def list(team_id, opts \\ []) do
    GenServer.call(via(team_id), {:list, opts})
  end

  @doc "Get remaining seconds until delivery for a scheduled message."
  @spec time_remaining(String.t(), String.t()) :: {:ok, integer()} | {:error, :not_found}
  def time_remaining(team_id, message_id) do
    GenServer.call(via(team_id), {:time_remaining, message_id})
  end

  defp via(team_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:message_scheduler, team_id}}}
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)

    state = %{
      team_id: team_id,
      scheduled: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:schedule, content, target_agent, deliver_at, opts}, _from, state) do
    now = DateTime.utc_now()

    case DateTime.compare(deliver_at, now) do
      :lt ->
        {:reply, {:error, :in_the_past}, state}

      _ ->
        delay_ms = DateTime.diff(deliver_at, now, :millisecond)
        id = generate_id()
        timer_ref = Process.send_after(self(), {:deliver, id}, delay_ms)

        msg = %ScheduledMessage{
          id: id,
          content: content,
          target_agent: target_agent,
          team_id: state.team_id,
          deliver_at: deliver_at,
          scheduled_at: now,
          status: :pending,
          timer_ref: timer_ref,
          metadata: Keyword.get(opts, :metadata)
        }

        state = put_in(state.scheduled[id], msg)
        broadcast_update(state)
        {:reply, {:ok, msg}, state}
    end
  end

  @impl true
  def handle_call({:cancel, message_id}, _from, state) do
    case Map.fetch(state.scheduled, message_id) do
      {:ok, %ScheduledMessage{status: :pending} = msg} ->
        Process.cancel_timer(msg.timer_ref)
        updated = %{msg | status: :cancelled, timer_ref: nil}
        state = put_in(state.scheduled[message_id], updated)
        broadcast_update(state)
        {:reply, :ok, state}

      {:ok, _msg} ->
        {:reply, {:error, :not_pending}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:edit, message_id, changes}, _from, state) do
    case Map.fetch(state.scheduled, message_id) do
      {:ok, %ScheduledMessage{status: :pending} = msg} ->
        with {:ok, msg} <- maybe_update_content(msg, changes),
             {:ok, msg} <- maybe_update_deliver_at(msg, message_id, changes) do
          state = put_in(state.scheduled[message_id], msg)
          broadcast_update(state)
          {:reply, {:ok, msg}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:ok, _msg} ->
        {:reply, {:error, :not_pending}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    status_filter = Keyword.get(opts, :status, :pending)

    messages =
      state.scheduled
      |> Map.values()
      |> then(fn msgs ->
        if status_filter == :all do
          msgs
        else
          Enum.filter(msgs, &(&1.status == status_filter))
        end
      end)
      |> Enum.sort_by(& &1.deliver_at, DateTime)

    {:reply, messages, state}
  end

  @impl true
  def handle_call({:time_remaining, message_id}, _from, state) do
    case Map.fetch(state.scheduled, message_id) do
      {:ok, %ScheduledMessage{status: :pending, deliver_at: deliver_at}} ->
        seconds = DateTime.diff(deliver_at, DateTime.utc_now())
        {:reply, {:ok, max(seconds, 0)}, state}

      {:ok, _msg} ->
        {:reply, {:error, :not_pending}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:deliver, message_id}, state) do
    case Map.fetch(state.scheduled, message_id) do
      {:ok, %ScheduledMessage{status: :pending} = msg} ->
        state = attempt_delivery(state, msg)
        {:noreply, state}

      _ ->
        # Already cancelled or delivered
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:retry_deliver, message_id}, state) do
    case Map.fetch(state.scheduled, message_id) do
      {:ok, %ScheduledMessage{status: :pending} = msg} ->
        state = attempt_delivery(state, msg)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    for {_id, %ScheduledMessage{timer_ref: ref}} when ref != nil <- state.scheduled do
      Process.cancel_timer(ref)
    end

    :ok
  end

  # --- Private ---

  defp maybe_update_content(msg, changes) do
    if Map.has_key?(changes, :content) do
      {:ok, %{msg | content: changes.content}}
    else
      {:ok, msg}
    end
  end

  defp maybe_update_deliver_at(msg, message_id, changes) do
    if Map.has_key?(changes, :deliver_at) do
      new_deliver_at = changes.deliver_at
      now = DateTime.utc_now()

      if DateTime.compare(new_deliver_at, now) == :lt do
        {:error, :in_the_past}
      else
        Process.cancel_timer(msg.timer_ref)
        delay_ms = DateTime.diff(new_deliver_at, now, :millisecond)
        new_timer = Process.send_after(self(), {:deliver, message_id}, delay_ms)
        {:ok, %{msg | deliver_at: new_deliver_at, timer_ref: new_timer}}
      end
    else
      {:ok, msg}
    end
  end

  defp attempt_delivery(state, msg) do
    case Manager.find_agent(msg.team_id, msg.target_agent) do
      {:ok, pid} ->
        try do
          Agent.send_message(pid, msg.content)
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end
        |> case do
          {:error, :busy} when msg.retry_count < @max_retries ->
            timer_ref = Process.send_after(self(), {:retry_deliver, msg.id}, @retry_delay_ms)
            updated = %{msg | timer_ref: timer_ref, retry_count: msg.retry_count + 1}
            put_in(state.scheduled[msg.id], updated)

          {:error, :busy} ->
            updated = %{msg | status: :failed, timer_ref: nil}
            state = put_in(state.scheduled[msg.id], updated)
            broadcast_update(state)
            state

          {:error, _reason} ->
            updated = %{msg | status: :failed, timer_ref: nil}
            state = put_in(state.scheduled[msg.id], updated)
            broadcast_update(state)
            state

          _ok ->
            updated = %{msg | status: :delivered, timer_ref: nil}
            state = put_in(state.scheduled[msg.id], updated)

            Phoenix.PubSub.broadcast(
              Loomkin.PubSub,
              "team:#{state.team_id}",
              {:scheduled_delivered, msg.id, msg.target_agent}
            )

            broadcast_update(state)
            state
        end

      :error ->
        updated = %{msg | status: :failed, timer_ref: nil}
        state = put_in(state.scheduled[msg.id], updated)
        broadcast_update(state)
        state
    end
  end

  defp broadcast_update(state) do
    pending = list_pending(state)

    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "team:#{state.team_id}",
      {:schedule_updated, state.team_id, pending}
    )
  end

  defp list_pending(state) do
    state.scheduled
    |> Map.values()
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.sort_by(& &1.deliver_at, DateTime)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
