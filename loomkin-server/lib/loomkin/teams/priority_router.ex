defmodule Loomkin.Teams.PriorityRouter do
  @moduledoc """
  Pure classification module for incoming PubSub messages.

  Routes messages by priority level so the Agent GenServer can
  queue or handle them appropriately during active loops.

  ## Priority Levels

    * `:urgent` — requires immediate action (abort, budget, conflicts)
    * `:high` — important but can be queued briefly (task assignments, unblocks)
    * `:normal` — standard messages (context, peers, queries, debate/pair)
    * `:ignore` — status/role noise that can be safely dropped during a loop
  """

  @urgent_types ~w(abort_task budget_exceeded file_conflict)a
  @high_types ~w(task_assigned tasks_unblocked confidence_warning review_response plan_revision conflict_detected collective_decision_result vote_request task_milestone task_priority_changed task_ready_for_review task_blocked rendezvous_completed rendezvous_timed_out task_negotiation_offer negotiation_timeout)a
  @ignore_types ~w(agent_status role_changed role_change_request)a

  @doc """
  Classify a PubSub message tuple by priority.

  Returns `{priority, message_type}` where priority is one of
  `:urgent`, `:high`, `:normal`, or `:ignore`.

  ## Examples

      iex> PriorityRouter.classify({:abort_task, "out of budget"})
      {:urgent, :abort_task}

      iex> PriorityRouter.classify({:task_assigned, "t1", "coder-1"})
      {:high, :task_assigned}

      iex> PriorityRouter.classify({:peer_message, "lead", "hello"})
      {:normal, :peer_message}

      iex> PriorityRouter.classify({:agent_status, "coder-1", :idle})
      {:ignore, :agent_status}
  """
  @spec classify(tuple()) :: {:urgent | :high | :normal | :ignore, atom()}
  def classify(msg) when is_tuple(msg) and tuple_size(msg) > 0 do
    type = elem(msg, 0)

    cond do
      type in @urgent_types -> {:urgent, type}
      type in @high_types -> {:high, type}
      type in @ignore_types -> {:ignore, type}
      true -> {:normal, type}
    end
  end

  def classify(_msg), do: {:normal, :unknown}
end
