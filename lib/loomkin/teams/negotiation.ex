defmodule Loomkin.Teams.Negotiation do
  @moduledoc """
  Per-team GenServer for task assignment negotiations.

  When a task is assigned with `negotiable: true`, a negotiation window opens.
  The assigned agent can accept, decline, or counter-propose. If no response
  arrives within the timeout, the assignment is auto-accepted.

  Status flow: `:pending_response` → `:negotiating` | `:accepted` | `:timed_out`
  """

  use GenServer

  alias Loomkin.Decisions.Graph
  alias Loomkin.Signals
  alias Loomkin.Signals.Extensions.Causality
  alias Loomkin.Teams.Comms

  @default_timeout_ms 30_000

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
  end

  @doc "Start a negotiation for a task assignment."
  @spec start_negotiation(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_negotiation(team_id, task_id, agent_name, opts \\ []) do
    case find(team_id) do
      {:ok, pid} ->
        GenServer.call(pid, {:start_negotiation, task_id, agent_name, opts})

      :error ->
        {:error, :negotiation_not_running}
    end
  end

  @doc "Agent responds to a negotiation."
  @spec respond(String.t(), String.t(), :accept | {:negotiate, String.t(), String.t()} | :decline) ::
          :ok | {:error, term()}
  def respond(team_id, task_id, response) do
    case find(team_id) do
      {:ok, pid} -> GenServer.call(pid, {:respond, task_id, response})
      :error -> {:error, :negotiation_not_running}
    end
  end

  @doc "Lead resolves a negotiation."
  @spec resolve(String.t(), String.t(), :accept_negotiation | :override | :reassign) ::
          :ok | {:error, term()}
  def resolve(team_id, task_id, resolution) do
    case find(team_id) do
      {:ok, pid} -> GenServer.call(pid, {:resolve, task_id, resolution})
      :error -> {:error, :negotiation_not_running}
    end
  end

  @doc "Cancel a pending negotiation."
  @spec cancel(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel(team_id, task_id) do
    case find(team_id) do
      {:ok, pid} -> GenServer.call(pid, {:cancel, task_id})
      :error -> {:error, :negotiation_not_running}
    end
  end

  @doc "List all active negotiations for a team."
  @spec list_negotiations(String.t()) :: [map()]
  def list_negotiations(team_id) do
    case find(team_id) do
      {:ok, pid} -> GenServer.call(pid, :list_negotiations)
      :error -> []
    end
  end

  @doc "Get the status of a specific negotiation."
  @spec negotiation_status(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def negotiation_status(team_id, task_id) do
    case find(team_id) do
      {:ok, pid} -> GenServer.call(pid, {:negotiation_status, task_id})
      :error -> {:error, :negotiation_not_running}
    end
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)

    state = %{
      team_id: team_id,
      negotiations: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_negotiation, task_id, agent_name, opts}, _from, state) do
    if Map.has_key?(state.negotiations, task_id) do
      {:reply, {:error, :already_negotiating}, state}
    else
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      timer_ref = Process.send_after(self(), {:negotiation_timeout, task_id}, timeout_ms)

      negotiation = %{
        task_id: task_id,
        agent_name: agent_name,
        status: :pending_response,
        proposal: nil,
        timeout_ref: timer_ref,
        started_at: DateTime.utc_now()
      }

      state = put_in(state.negotiations[task_id], negotiation)

      publish_started(state.team_id, task_id, agent_name)

      {:reply, {:ok, task_id}, state}
    end
  end

  @impl true
  def handle_call({:respond, task_id, response}, _from, state) do
    case Map.fetch(state.negotiations, task_id) do
      {:ok, %{status: :pending_response} = neg} ->
        case response do
          :accept ->
            if neg.timeout_ref, do: Process.cancel_timer(neg.timeout_ref)

            publish_resolved(state.team_id, task_id, neg.agent_name, :accepted)
            log_negotiation_decision(state.team_id, task_id, neg.agent_name, :accepted, nil)

            state = %{state | negotiations: Map.delete(state.negotiations, task_id)}
            {:reply, :ok, state}

          {:negotiate, reason, counter_proposal} ->
            neg = %{
              neg
              | status: :negotiating,
                proposal: %{reason: reason, counter_proposal: counter_proposal}
            }

            state = put_in(state.negotiations[task_id], neg)

            publish_offer(state.team_id, task_id, neg.agent_name, reason, counter_proposal)

            {:reply, :ok, state}

          :decline ->
            if neg.timeout_ref, do: Process.cancel_timer(neg.timeout_ref)

            publish_resolved(state.team_id, task_id, neg.agent_name, :declined)
            log_negotiation_decision(state.team_id, task_id, neg.agent_name, :declined, nil)

            state = %{state | negotiations: Map.delete(state.negotiations, task_id)}
            {:reply, :ok, state}
        end

      {:ok, %{status: status}} ->
        {:reply, {:error, {:invalid_status, status}}, state}

      :error ->
        {:reply, {:error, :negotiation_not_found}, state}
    end
  end

  @impl true
  def handle_call({:resolve, task_id, resolution}, _from, state) do
    case Map.fetch(state.negotiations, task_id) do
      {:ok, %{status: :negotiating} = neg} ->
        if neg.timeout_ref, do: Process.cancel_timer(neg.timeout_ref)

        publish_resolved(state.team_id, task_id, neg.agent_name, resolution)
        log_negotiation_decision(state.team_id, task_id, neg.agent_name, resolution, neg.proposal)

        state = %{state | negotiations: Map.delete(state.negotiations, task_id)}
        {:reply, :ok, state}

      {:ok, %{status: status}} ->
        {:reply, {:error, {:invalid_status, status}}, state}

      :error ->
        {:reply, {:error, :negotiation_not_found}, state}
    end
  end

  @impl true
  def handle_call({:cancel, task_id}, _from, state) do
    case Map.fetch(state.negotiations, task_id) do
      {:ok, neg} ->
        if neg.timeout_ref, do: Process.cancel_timer(neg.timeout_ref)
        state = %{state | negotiations: Map.delete(state.negotiations, task_id)}
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :negotiation_not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_negotiations, _from, state) do
    negotiations =
      Enum.map(state.negotiations, fn {task_id, neg} ->
        %{
          task_id: task_id,
          agent_name: neg.agent_name,
          status: neg.status,
          proposal: neg.proposal,
          started_at: neg.started_at
        }
      end)

    {:reply, negotiations, state}
  end

  @impl true
  def handle_call({:negotiation_status, task_id}, _from, state) do
    case Map.fetch(state.negotiations, task_id) do
      {:ok, neg} ->
        status = %{
          task_id: task_id,
          agent_name: neg.agent_name,
          status: neg.status,
          proposal: neg.proposal,
          started_at: neg.started_at
        }

        {:reply, {:ok, status}, state}

      :error ->
        {:reply, {:error, :negotiation_not_found}, state}
    end
  end

  # --- Timeout handler ---

  @impl true
  def handle_info({:negotiation_timeout, task_id}, state) do
    case Map.fetch(state.negotiations, task_id) do
      {:ok, neg} ->
        publish_timed_out(state.team_id, task_id, neg.agent_name)
        log_negotiation_decision(state.team_id, task_id, neg.agent_name, :timed_out, neg.proposal)

        Comms.broadcast(
          state.team_id,
          {:negotiation_timeout, task_id, neg.agent_name}
        )

        state = %{state | negotiations: Map.delete(state.negotiations, task_id)}
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # Catch-all
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp via(team_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:negotiation, team_id}}}
  end

  defp find(team_id) do
    case Registry.lookup(Loomkin.Teams.AgentRegistry, {:negotiation, team_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp publish_started(team_id, task_id, agent_name) do
    Signals.Team.TaskNegotiationStarted.new!(%{
      task_id: task_id,
      agent_name: to_string(agent_name),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(agent_name))
    |> Signals.publish()
  end

  defp publish_offer(team_id, task_id, agent_name, reason, counter_proposal) do
    Signals.Team.TaskNegotiationOffer.new!(%{
      task_id: task_id,
      agent_name: to_string(agent_name),
      reason: reason,
      counter_proposal: counter_proposal,
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(agent_name))
    |> Signals.publish()
  end

  defp publish_resolved(team_id, task_id, agent_name, resolution) do
    Signals.Team.TaskNegotiationResolved.new!(%{
      task_id: task_id,
      agent_name: to_string(agent_name),
      resolution: to_string(resolution),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(agent_name))
    |> Signals.publish()
  end

  defp publish_timed_out(team_id, task_id, agent_name) do
    Signals.Team.TaskNegotiationTimedOut.new!(%{
      task_id: task_id,
      agent_name: to_string(agent_name),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(agent_name))
    |> Signals.publish()
  end

  defp log_negotiation_decision(team_id, task_id, agent_name, resolution, proposal) do
    # Log decision node
    case Graph.add_node(%{
           node_type: :decision,
           title: "Assignment negotiation for task #{task_id}",
           agent_name: to_string(agent_name),
           metadata: %{"team_id" => team_id, "task_id" => task_id, "negotiation" => true}
         }) do
      {:ok, decision_node} ->
        # Log proposal as option node if present
        if proposal do
          case Graph.add_node(%{
                 node_type: :option,
                 title: "Counter-proposal: #{proposal.reason}",
                 description: proposal.counter_proposal,
                 agent_name: to_string(agent_name),
                 metadata: %{"team_id" => team_id, "task_id" => task_id}
               }) do
            {:ok, option_node} ->
              Graph.add_edge(decision_node.id, option_node.id, :leads_to)

            _ ->
              :ok
          end
        end

        # Log resolution as outcome node
        case Graph.add_node(%{
               node_type: :outcome,
               title: "Resolution: #{resolution}",
               agent_name: to_string(agent_name),
               metadata: %{"team_id" => team_id, "task_id" => task_id}
             }) do
          {:ok, outcome_node} ->
            Graph.add_edge(decision_node.id, outcome_node.id, :chosen)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
