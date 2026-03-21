defmodule Loomkin.Teams.Comms do
  @moduledoc "Convenience functions wrapping Jido Signal Bus for team communication."

  require Logger

  alias Loomkin.Signals
  alias Loomkin.Signals.Extensions.Causality
  alias Loomkin.Teams.Topics

  @doc """
  Subscribe agent to team signal paths based on role.

  Leads and concierge get full subscriptions (all 5 paths).
  Specialists get a reduced set (team, collaboration, context) to avoid
  unnecessary handle_info calls from agent and decision signals they no-op on.

  Returns `{:ok, subscription_ids}` where `subscription_ids` is a list of
  subscription references that can be passed to `unsubscribe/1` for cleanup.
  """
  def subscribe(team_id, agent_name, opts \\ [])

  def subscribe(_team_id, _agent_name, opts) do
    role = Keyword.get(opts, :role)

    paths =
      if role in [:lead, :concierge] or is_nil(role) do
        [
          Topics.agent_all(),
          Topics.team_all(),
          Topics.context_all(),
          Topics.collaboration_all(),
          Topics.decision_all()
        ]
      else
        [
          Topics.team_all(),
          Topics.collaboration_all(),
          Topics.context_all()
        ]
      end

    subscription_ids =
      Enum.reduce(paths, [], fn path, acc ->
        case Signals.subscribe(path) do
          {:ok, sub_id} -> [sub_id | acc]
          _other -> acc
        end
      end)

    {:ok, Enum.reverse(subscription_ids)}
  end

  @doc """
  Unsubscribe from the signal bus using previously tracked subscription IDs.

  Accepts the list of subscription IDs returned by `subscribe/2`.
  """
  def unsubscribe(subscription_ids) when is_list(subscription_ids) do
    Enum.each(subscription_ids, &Signals.unsubscribe/1)
    :ok
  end

  @doc "Send a direct message to a specific agent."
  def send_to(team_id, agent_name, message) do
    signal =
      Loomkin.Signals.Collaboration.PeerMessage.new!(
        %{from: "system", team_id: team_id},
        subject: to_string(agent_name)
      )

    %{signal | data: Map.merge(signal.data, %{target: to_string(agent_name), message: message})}
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  @doc "Broadcast a message to the entire team."
  def broadcast(team_id, message) do
    signal =
      Loomkin.Signals.Collaboration.PeerMessage.new!(%{from: "system", team_id: team_id})

    %{signal | data: Map.merge(signal.data, %{message: message})}
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  @doc """
  Share a discovery via the context topic.

  ## Options

    * `:propagate_up` - if true, also broadcast to parent team for `:insight` and
      `:blocker` type discoveries. Defaults to `true`.

  """
  def broadcast_context(team_id, payload, opts \\ [])

  def broadcast_context(_team_id, %{from: nil} = payload, _opts) do
    Logger.warning(
      "[Kin:data] broadcast_context called with nil :from, keys=#{inspect(Map.keys(payload))}"
    )

    :ok
  end

  def broadcast_context(team_id, %{from: from} = payload, opts) do
    signal = Loomkin.Signals.Context.Update.new!(%{from: to_string(from), team_id: team_id})

    %{signal | data: Map.merge(signal.data, %{payload: payload})}
    |> Causality.attach(team_id: team_id, agent_name: to_string(from))
    |> Signals.publish()

    propagate_up = Keyword.get(opts, :propagate_up, true)

    if propagate_up do
      maybe_propagate_to_parent(team_id, payload)
    end

    :ok
  end

  @doc """
  Broadcast a discovery only to agents whose relevance score exceeds the threshold.

  Falls back to full broadcast if no agents are registered or scoring fails.
  """
  def broadcast_context_targeted(team_id, %{from: from} = payload, threshold \\ 0.3) do
    alias Loomkin.Teams.Context
    alias Loomkin.Teams.RelevanceScorer

    agents = Context.list_agents(team_id)

    if agents == [] do
      broadcast_context(team_id, payload)
    else
      other_agents = Enum.reject(agents, fn agent -> to_string(agent.name) == to_string(from) end)

      all_scored =
        Enum.map(other_agents, fn agent -> {agent, RelevanceScorer.score(payload, agent)} end)

      {relevant, skipped} =
        Enum.split_with(all_scored, fn {_agent, score} -> score >= threshold end)

      relevant = Enum.sort_by(relevant, fn {_agent, s} -> s end, :desc)

      if relevant == [] do
        broadcast_context(team_id, payload)
      else
        Enum.each(relevant, fn {agent, _score} ->
          send_to(team_id, agent.name, {:context_update, from, payload})
        end)

        # Emit a context.update signal with relevance metadata for UI visibility
        recipients = Enum.map(relevant, fn {agent, score} -> {to_string(agent.name), score} end)
        skipped_list = Enum.map(skipped, fn {agent, score} -> {to_string(agent.name), score} end)

        signal =
          Loomkin.Signals.Context.Update.new!(%{from: to_string(from), team_id: team_id})

        %{
          signal
          | data:
              Map.merge(signal.data, %{
                payload: payload,
                relevance: %{recipients: recipients, skipped: skipped_list}
              })
        }
        |> Causality.attach(team_id: team_id, agent_name: to_string(from))
        |> Signals.publish()
      end
    end
  end

  @doc "Send a message to an agent in any team. Alias for `send_to/3` that signals cross-boundary intent."
  def send_cross_team(target_team_id, target_agent, message) do
    send_to(target_team_id, target_agent, message)
  end

  @doc "Broadcast a message to all child teams."
  def broadcast_to_children(parent_team_id, message) do
    for child_id <- Loomkin.Teams.Manager.get_child_teams(parent_team_id) do
      broadcast(child_id, message)
    end

    :ok
  end

  @doc "Broadcast a message to sibling teams."
  def broadcast_to_siblings(team_id, message) do
    case Loomkin.Teams.Manager.get_sibling_teams(team_id) do
      {:ok, siblings} ->
        for sib_id <- siblings do
          broadcast(sib_id, message)
        end

        :ok

      :error ->
        :ok
    end
  end

  @doc "Broadcast a task event (assigned, completed, etc)."
  def broadcast_task_event(team_id, {:task_assigned, task_id, agent_name}) do
    Loomkin.Signals.Team.TaskAssigned.new!(%{
      task_id: task_id,
      agent_name: to_string(agent_name),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(agent_name), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_completed, task_id, owner, result}) do
    signal =
      Loomkin.Signals.Team.TaskCompleted.new!(%{
        task_id: task_id,
        owner: to_string(owner),
        team_id: team_id
      })

    %{signal | data: Map.put(signal.data, :result, result)}
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_failed, task_id, owner, reason}) do
    signal =
      Loomkin.Signals.Team.TaskFailed.new!(%{
        task_id: task_id,
        owner: to_string(owner),
        team_id: team_id
      })

    %{signal | data: Map.put(signal.data, :reason, reason)}
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_started, task_id, owner}) do
    Loomkin.Signals.Team.TaskStarted.new!(%{
      task_id: task_id,
      owner: to_string(owner),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_milestone, task_id, owner, milestone_name}) do
    Loomkin.Signals.Team.TaskMilestoneReached.new!(%{
      task_id: task_id,
      milestone_name: milestone_name,
      owner: to_string(owner || "unknown"),
      team_id: team_id
    })
    |> Causality.attach(
      team_id: team_id,
      agent_name: to_string(owner || "unknown"),
      task_id: task_id
    )
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_priority_changed, task_id, owner, new_priority}) do
    Loomkin.Signals.Team.TaskPriorityChanged.new!(%{
      task_id: task_id,
      owner: to_string(owner || "unknown"),
      new_priority: new_priority,
      team_id: team_id
    })
    |> Causality.attach(
      team_id: team_id,
      agent_name: to_string(owner || "unknown"),
      task_id: task_id
    )
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_ready_for_review, task_id, owner, summary}) do
    signal =
      Loomkin.Signals.Team.TaskReadyForReview.new!(%{
        task_id: task_id,
        owner: to_string(owner),
        team_id: team_id
      })

    %{signal | data: Map.put(signal.data, :summary, summary)}
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_blocked, task_id, owner, reason}) do
    signal =
      Loomkin.Signals.Team.TaskBlocked.new!(%{
        task_id: task_id,
        owner: to_string(owner),
        team_id: team_id
      })

    %{signal | data: Map.put(signal.data, :reason, reason)}
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_resumed, task_id, owner}) do
    Loomkin.Signals.Team.TaskResumed.new!(%{
      task_id: task_id,
      owner: to_string(owner),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_partially_complete, task_id, owner, partial_result}) do
    signal =
      Loomkin.Signals.Team.TaskPartiallyComplete.new!(%{
        task_id: task_id,
        owner: to_string(owner),
        team_id: team_id
      })

    %{signal | data: Map.put(signal.data, :partial_result, partial_result)}
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(
        team_id,
        {:task_speculative_started, task_id, based_on_task_id, assumed_output}
      ) do
    signal =
      Loomkin.Signals.Team.TaskSpeculativeStarted.new!(%{
        task_id: task_id,
        based_on_task_id: based_on_task_id,
        team_id: team_id
      })

    %{signal | data: Map.put(signal.data, :assumed_output, assumed_output)}
    |> Causality.attach(team_id: team_id, task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:assumption_violated, task_id, key, assumed, actual}) do
    Loomkin.Signals.Team.AssumptionViolated.new!(%{
      task_id: task_id,
      assumption_key: key,
      assumed_value: assumed,
      actual_value: actual,
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:speculative_confirmed, task_id}) do
    Loomkin.Signals.Team.SpeculativeConfirmed.new!(%{
      task_id: task_id,
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:speculative_discarded, task_id}) do
    Loomkin.Signals.Team.SpeculativeDiscarded.new!(%{
      task_id: task_id,
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, event) do
    # Fallback for other task events
    signal = Loomkin.Signals.Collaboration.PeerMessage.new!(%{from: "tasks", team_id: team_id})

    %{signal | data: Map.merge(signal.data, %{message: event})}
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  @doc "Broadcast a decision graph change."
  def broadcast_decision(team_id, node_id, agent_name) do
    Loomkin.Signals.Decision.DecisionLogged.new!(%{
      node_id: node_id,
      agent_name: to_string(agent_name),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(agent_name))
    |> Signals.publish()
  end

  # -- Private --

  @propagatable_types ~w[insight blocker discovery warning]

  defp maybe_propagate_to_parent(team_id, %{from: from} = payload) do
    type = to_string(payload[:type] || "")

    if type in @propagatable_types do
      case Loomkin.Teams.Manager.get_parent_team(team_id) do
        {:ok, parent_team_id} ->
          propagated = Map.put(payload, :source_team, team_id)

          signal =
            Loomkin.Signals.Context.Update.new!(%{
              from: to_string(from),
              team_id: parent_team_id
            })

          %{signal | data: Map.merge(signal.data, %{payload: propagated})}
          |> Causality.attach(team_id: team_id, agent_name: to_string(from))
          |> Signals.publish()

        :error ->
          :ok
      end
    end
  end
end
