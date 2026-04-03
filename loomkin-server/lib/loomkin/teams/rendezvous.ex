defmodule Loomkin.Teams.Rendezvous do
  @moduledoc """
  Per-team GenServer for synchronization barriers (rendezvous points).

  A barrier waits for a set of agents to signal readiness. Once all required
  agents have arrived, the on_complete callback is executed and a
  `RendezvousCompleted` signal is published. If the barrier times out before
  all agents arrive, a `RendezvousTimedOut` signal is published instead.
  """

  use GenServer

  alias Loomkin.Signals
  alias Loomkin.Signals.Extensions.Causality
  alias Loomkin.Teams.Comms

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
  end

  @doc "Create a synchronization barrier."
  @spec create_barrier(String.t(), String.t(), [String.t()], term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_barrier(team_id, name, required_agents, on_complete, opts \\ []) do
    case find(team_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:create_barrier, name, required_agents, on_complete, opts})

      :error ->
        {:error, :rendezvous_not_running}
    end
  end

  @doc "Signal that an agent has arrived at a barrier."
  @spec signal_ready(String.t(), String.t(), String.t()) ::
          {:ok, :arrived | :completed} | {:error, term()}
  def signal_ready(team_id, rendezvous_id, agent_name) do
    case find(team_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:signal_ready, rendezvous_id, to_string(agent_name)})

      :error ->
        {:error, :rendezvous_not_running}
    end
  end

  @doc "Cancel a barrier."
  @spec cancel_barrier(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel_barrier(team_id, rendezvous_id) do
    case find(team_id) do
      {:ok, pid} -> GenServer.call(pid, {:cancel_barrier, rendezvous_id})
      :error -> {:error, :rendezvous_not_running}
    end
  end

  @doc "List all active barriers for a team."
  @spec list_barriers(String.t()) :: [map()]
  def list_barriers(team_id) do
    case find(team_id) do
      {:ok, pid} -> GenServer.call(pid, :list_barriers)
      :error -> []
    end
  end

  @doc "Get the status of a specific barrier."
  @spec barrier_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def barrier_status(team_id, rendezvous_id) do
    case find(team_id) do
      {:ok, pid} -> GenServer.call(pid, {:barrier_status, rendezvous_id})
      :error -> {:error, :rendezvous_not_running}
    end
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)

    # Listen for agent crashes so we can remove them from required sets
    Signals.subscribe("agent.status")

    state = %{
      team_id: team_id,
      barriers: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_barrier, name, required_agents, on_complete, opts}, _from, state) do
    rendezvous_id = Ecto.UUID.generate()
    timeout_min = Keyword.get(opts, :timeout_minutes, 5)
    timeout_ms = timeout_min * 60_000

    timer_ref = Process.send_after(self(), {:barrier_timeout, rendezvous_id}, timeout_ms)

    barrier = %{
      name: name,
      required_agents: MapSet.new(required_agents),
      arrived: MapSet.new(),
      on_complete: on_complete,
      timeout_ms: timeout_ms,
      timer_ref: timer_ref,
      created_at: DateTime.utc_now()
    }

    state = put_in(state.barriers[rendezvous_id], barrier)

    # Publish created signal
    Loomkin.Signals.Team.RendezvousCreated.new!(%{
      rendezvous_id: rendezvous_id,
      name: name,
      team_id: state.team_id
    })
    |> Causality.attach(team_id: state.team_id)
    |> Signals.publish()

    {:reply, {:ok, rendezvous_id}, state}
  end

  @impl true
  def handle_call({:signal_ready, rendezvous_id, agent_name}, _from, state) do
    case Map.fetch(state.barriers, rendezvous_id) do
      {:ok, barrier} ->
        if not MapSet.member?(barrier.required_agents, agent_name) do
          {:reply, {:error, :not_required}, state}
        else
          barrier = %{barrier | arrived: MapSet.put(barrier.arrived, agent_name)}

          if MapSet.equal?(barrier.arrived, barrier.required_agents) do
            # All agents have arrived — complete the barrier
            if barrier.timer_ref, do: Process.cancel_timer(barrier.timer_ref)
            execute_on_complete(state.team_id, barrier)
            publish_completed(state.team_id, rendezvous_id, barrier.name)

            state = %{state | barriers: Map.delete(state.barriers, rendezvous_id)}
            {:reply, {:ok, :completed}, state}
          else
            state = put_in(state.barriers[rendezvous_id], barrier)
            {:reply, {:ok, :arrived}, state}
          end
        end

      :error ->
        {:reply, {:error, :barrier_not_found}, state}
    end
  end

  @impl true
  def handle_call({:cancel_barrier, rendezvous_id}, _from, state) do
    case Map.fetch(state.barriers, rendezvous_id) do
      {:ok, barrier} ->
        if barrier.timer_ref, do: Process.cancel_timer(barrier.timer_ref)
        state = %{state | barriers: Map.delete(state.barriers, rendezvous_id)}
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :barrier_not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_barriers, _from, state) do
    barriers =
      Enum.map(state.barriers, fn {id, b} ->
        %{
          id: id,
          name: b.name,
          required_agents: MapSet.to_list(b.required_agents),
          arrived: MapSet.to_list(b.arrived),
          created_at: b.created_at
        }
      end)

    {:reply, barriers, state}
  end

  @impl true
  def handle_call({:barrier_status, rendezvous_id}, _from, state) do
    case Map.fetch(state.barriers, rendezvous_id) do
      {:ok, b} ->
        status = %{
          id: rendezvous_id,
          name: b.name,
          required_agents: MapSet.to_list(b.required_agents),
          arrived: MapSet.to_list(b.arrived),
          waiting_for: MapSet.to_list(MapSet.difference(b.required_agents, b.arrived)),
          created_at: b.created_at
        }

        {:reply, {:ok, status}, state}

      :error ->
        {:reply, {:error, :barrier_not_found}, state}
    end
  end

  # --- Timeout handler ---

  @impl true
  def handle_info({:barrier_timeout, rendezvous_id}, state) do
    case Map.fetch(state.barriers, rendezvous_id) do
      {:ok, barrier} ->
        publish_timed_out(state.team_id, rendezvous_id, barrier.name)

        waiting =
          MapSet.difference(barrier.required_agents, barrier.arrived) |> MapSet.to_list()

        Comms.broadcast(
          state.team_id,
          {:rendezvous_timed_out, rendezvous_id, barrier.name, waiting}
        )

        state = %{state | barriers: Map.delete(state.barriers, rendezvous_id)}
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # Handle agent crash — remove from required_agents
  @impl true
  def handle_info({:signal, %Jido.Signal{} = sig}, state) do
    if signal_for_team?(sig, state.team_id) do
      handle_info(sig, state)
    else
      {:noreply, state}
    end
  end

  def handle_info(
        %Jido.Signal{type: "agent.status", data: %{agent_name: name, status: status}},
        state
      )
      when status in [:error, :crashed] do
    agent_name = to_string(name)

    # Remove crashed agent from all barriers' required sets
    barriers =
      Map.new(state.barriers, fn {id, barrier} ->
        if MapSet.member?(barrier.required_agents, agent_name) do
          updated = %{
            barrier
            | required_agents: MapSet.delete(barrier.required_agents, agent_name),
              arrived: MapSet.delete(barrier.arrived, agent_name)
          }

          # Check if barrier is now complete after removal
          if MapSet.equal?(updated.arrived, updated.required_agents) and
               MapSet.size(updated.required_agents) > 0 do
            if updated.timer_ref, do: Process.cancel_timer(updated.timer_ref)
            execute_on_complete(state.team_id, updated)
            publish_completed(state.team_id, id, updated.name)
            {id, :remove}
          else
            {id, updated}
          end
        else
          {id, barrier}
        end
      end)
      |> Enum.reject(fn {_id, v} -> v == :remove end)
      |> Map.new()

    {:noreply, %{state | barriers: barriers}}
  end

  # Catch-all for unmatched signals and messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp via(team_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:rendezvous, team_id}}}
  end

  defp find(team_id) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:rendezvous, team_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp execute_on_complete(team_id, barrier) do
    case barrier.on_complete do
      msg when is_binary(msg) ->
        Comms.broadcast(team_id, {:rendezvous_completed, msg})

      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp publish_completed(team_id, rendezvous_id, name) do
    Loomkin.Signals.Team.RendezvousCompleted.new!(%{
      rendezvous_id: rendezvous_id,
      name: name,
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  defp publish_timed_out(team_id, rendezvous_id, name) do
    Loomkin.Signals.Team.RendezvousTimedOut.new!(%{
      rendezvous_id: rendezvous_id,
      name: name,
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  defp signal_for_team?(sig, team_id) do
    signal_team_id =
      get_in(sig.data, [:team_id]) ||
        get_in(sig, [Access.key(:extensions, %{}), "loomkin", "team_id"])

    signal_team_id == nil or signal_team_id == team_id
  end
end
