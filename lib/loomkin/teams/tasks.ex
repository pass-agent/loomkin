defmodule Loomkin.Teams.Tasks do
  @moduledoc "CRUD + coordination logic for team tasks."

  require Logger
  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.TaskAssumption
  alias Loomkin.Schemas.TeamTask
  alias Loomkin.Schemas.TeamTaskDep
  alias Loomkin.Teams.Capabilities
  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Context
  alias Loomkin.Teams.CostTracker
  alias Loomkin.Teams.Learning
  alias Loomkin.Verification.UpstreamVerifier

  def create_task(team_id, attrs) do
    %TeamTask{}
    |> TeamTask.changeset(Map.merge(attrs, %{team_id: team_id, status: :pending}))
    |> Repo.insert()
    |> tap_ok(fn task ->
      Comms.broadcast_task_event(team_id, {:task_created, task.id, task.title})

      Context.cache_task(team_id, task.id, %{
        title: task.title,
        status: task.status,
        owner: task.owner
      })
    end)
  end

  def assign_task(task_id, agent_name, opts \\ []) do
    get_task!(task_id)
    |> TeamTask.changeset(%{owner: agent_name, status: :assigned})
    |> Repo.update()
    |> tap_ok(fn task ->
      Comms.broadcast_task_event(task.team_id, {:task_assigned, task.id, agent_name})

      Context.cache_task(task.team_id, task.id, %{
        title: task.title,
        status: :assigned,
        owner: agent_name
      })

      if Keyword.get(opts, :negotiable, false) do
        Loomkin.Teams.Negotiation.start_negotiation(
          task.team_id,
          task.id,
          agent_name,
          Keyword.take(opts, [:timeout_ms])
        )
      end
    end)
  end

  def start_task(task_id) do
    get_task!(task_id)
    |> TeamTask.changeset(%{status: :in_progress})
    |> Repo.update()
    |> tap_ok(fn task ->
      Comms.broadcast_task_event(task.team_id, {:task_started, task.id, task.owner})

      Context.cache_task(task.team_id, task.id, %{
        title: task.title,
        status: :in_progress,
        owner: task.owner
      })
    end)
  end

  def complete_task(task_id, result) when is_binary(result) do
    complete_task(task_id, %{result: result})
  end

  def complete_task(task_id, attrs) when is_map(attrs) do
    case get_task(task_id) do
      {:ok, task} -> do_complete_task(task, attrs)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp do_complete_task(task, attrs) do
    result = get_flexible(attrs, :result, "result") || ""

    if task.status in [:completed, :failed] do
      {:ok, task}
    else
      changeset_attrs = %{
        status: :completed,
        result: result,
        actions_taken: get_flexible(attrs, :actions_taken, "actions_taken") || [],
        discoveries: get_flexible(attrs, :discoveries, "discoveries") || [],
        files_changed: get_flexible(attrs, :files_changed, "files_changed") || [],
        decisions_made: get_flexible(attrs, :decisions_made, "decisions_made") || [],
        open_questions: get_flexible(attrs, :open_questions, "open_questions") || []
      }

      # Warn when task is completed with no substantive artifacts
      if empty_artifacts?(changeset_attrs) do
        Logger.warning(
          "[Tasks] Task #{task.id} (#{task.title}) completed by #{task.owner} with no artifacts " <>
            "(no actions_taken, discoveries, or files_changed). Result: #{String.slice(result, 0..100)}"
        )

        Comms.broadcast_task_event(
          task.team_id,
          {:task_quality_warning, task.id, task.owner,
           "Task completed without artifacts — no actions, discoveries, or files changed"}
        )
      end

      task
      |> TeamTask.changeset(changeset_attrs)
      |> Repo.update()
      |> tap_ok(fn task ->
        # Persist accumulated cost/tokens from CostTracker for the owning agent
        if task.owner do
          usage = CostTracker.get_agent_usage(task.team_id, task.owner)

          CostTracker.persist_task_cost(
            task.id,
            usage.cost,
            usage.input_tokens + usage.output_tokens
          )
        end

        Comms.broadcast_task_event(task.team_id, {:task_completed, task.id, task.owner, result})

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: :completed,
          owner: task.owner
        })

        record_capability(task, :success)
        record_learning_metric(task, true)
        maybe_verify_before_unblocking(task)

        case validate_speculative_dependents(task) do
          {:error, reason} ->
            Logger.warning("validate_speculative_dependents failed: #{inspect(reason)}")

          _ ->
            :ok
        end
      end)
    end
  end

  def fail_task(task_id, reason) do
    case Ecto.UUID.cast(task_id) do
      :error ->
        {:error, :not_a_db_task}

      {:ok, _} ->
        task = get_task!(task_id)

        if task.status in [:completed, :failed] do
          {:ok, task}
        else
          task
          |> TeamTask.changeset(%{status: :failed, result: reason})
          |> Repo.update()
          |> tap_ok(fn task ->
            Comms.broadcast_task_event(task.team_id, {:task_failed, task.id, task.owner, reason})

            Context.cache_task(task.team_id, task.id, %{
              title: task.title,
              status: :failed,
              owner: task.owner
            })

            record_capability(task, :failure)
            record_learning_metric(task, false)
          end)
        end
    end
  end

  def mark_ready_for_review(task_id, summary) do
    task = get_task!(task_id)

    if task.status != :in_progress do
      {:error, :invalid_transition}
    else
      task
      |> TeamTask.changeset(%{status: :ready_for_review, result: summary})
      |> Repo.update()
      |> tap_ok(fn task ->
        Comms.broadcast_task_event(
          task.team_id,
          {:task_ready_for_review, task.id, task.owner, summary}
        )

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: :ready_for_review,
          owner: task.owner
        })
      end)
    end
  end

  def mark_blocked(task_id, reason) do
    task = get_task!(task_id)

    if task.status not in [:assigned, :in_progress] do
      {:error, :invalid_transition}
    else
      task
      |> TeamTask.changeset(%{status: :blocked, result: reason})
      |> Repo.update()
      |> tap_ok(fn task ->
        Comms.broadcast_task_event(task.team_id, {:task_blocked, task.id, task.owner, reason})

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: :blocked,
          owner: task.owner
        })
      end)
    end
  end

  def mark_partially_complete(task_id, partial_result) when is_binary(partial_result) do
    mark_partially_complete(task_id, %{output: partial_result})
  end

  def mark_partially_complete(task_id, partial_data) when is_map(partial_data) do
    task = get_task!(task_id)

    if task.status != :in_progress do
      {:error, :invalid_transition}
    else
      completed_items = get_flexible(partial_data, :completed_items, "completed_items")
      total_items = get_flexible(partial_data, :total_items, "total_items")
      output = get_flexible(partial_data, :output, "output") || ""
      next_steps = get_flexible(partial_data, :next_steps, "next_steps")

      partial_results = %{
        "completed_items" => completed_items,
        "total_items" => total_items,
        "output" => output,
        "next_steps" => next_steps
      }

      summary =
        if completed_items && total_items do
          "#{completed_items}/#{total_items} items complete. #{output}"
        else
          to_string(output)
        end

      attrs = %{
        status: :partially_complete,
        result: summary,
        partial_results: partial_results,
        completed_items: completed_items,
        total_items: total_items
      }

      task
      |> TeamTask.changeset(attrs)
      |> Repo.update()
      |> tap_ok(fn task ->
        Comms.broadcast_task_event(
          task.team_id,
          {:task_partially_complete, task.id, task.owner, partial_results}
        )

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: :partially_complete,
          owner: task.owner
        })

        auto_schedule_unblocked(task.team_id)
      end)
    end
  end

  @doc """
  Resume a partially complete task, transitioning it back to `:in_progress`.

  Preserves the partial result context so the agent can continue where it left off.
  Returns `{:ok, task}` or `{:error, :invalid_transition}`.
  """
  def resume_task(task_id) do
    task = get_task!(task_id)

    if task.status != :partially_complete do
      {:error, :invalid_transition}
    else
      task
      |> TeamTask.changeset(%{status: :in_progress})
      |> Repo.update()
      |> tap_ok(fn task ->
        Comms.broadcast_task_event(task.team_id, {:task_resumed, task.id, task.owner})

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: :in_progress,
          owner: task.owner
        })
      end)
    end
  end

  @doc """
  Add a dependency between two tasks.

  ## Options

    * `:milestone_name` - optional milestone name for milestone-based deps

  Returns `{:ok, dep}` or `{:error, reason}`.
  Rejects cycles via recursive CTE.
  """
  def add_dependency(task_id, depends_on_id, dep_type \\ :blocks, opts \\ []) do
    milestone_name = Keyword.get(opts, :milestone_name)

    if detect_cycle?(depends_on_id, task_id) do
      {:error, :cycle_detected}
    else
      %TeamTaskDep{}
      |> TeamTaskDep.changeset(%{
        task_id: task_id,
        depends_on_id: depends_on_id,
        dep_type: dep_type,
        milestone_name: milestone_name
      })
      |> Repo.insert()
    end
  end

  @doc """
  Returns predecessor output data for completed or partially complete `:requires_output` dependencies.

  Returns a list of maps with task_id, title, result, structured fields, and partial flag.
  Completed tasks return their full result and structured details. Partially complete tasks
  return their partial results with `partial: true`.
  """
  def get_predecessor_outputs(task_id) do
    completed =
      Repo.all(
        from d in TeamTaskDep,
          join: dep in TeamTask,
          on: d.depends_on_id == dep.id,
          where:
            d.task_id == ^task_id and d.dep_type == :requires_output and dep.status == :completed,
          select: %{
            task_id: dep.id,
            title: dep.title,
            result: dep.result,
            actions_taken: dep.actions_taken,
            discoveries: dep.discoveries,
            files_changed: dep.files_changed,
            decisions_made: dep.decisions_made,
            open_questions: dep.open_questions
          }
      )
      |> Enum.map(&Map.put(&1, :partial, false))

    partial =
      Repo.all(
        from d in TeamTaskDep,
          join: dep in TeamTask,
          on: d.depends_on_id == dep.id,
          where:
            d.task_id == ^task_id and d.dep_type == :requires_output and
              dep.status == :partially_complete,
          select: %{
            task_id: dep.id,
            title: dep.title,
            result: dep.result,
            partial_results: dep.partial_results,
            partial: true
          }
      )

    completed ++ partial
  end

  @doc """
  Emit a named milestone for a task.

  Appends the milestone to `milestones_emitted`, broadcasts a signal,
  and checks if any milestone-dependent tasks are now unblocked.
  """
  def emit_milestone(team_id, task_id, milestone_name) do
    task = get_task!(task_id)

    if milestone_name in (task.milestones_emitted || []) do
      {:ok, task}
    else
      new_milestones = (task.milestones_emitted || []) ++ [milestone_name]

      task
      |> TeamTask.changeset(%{milestones_emitted: new_milestones})
      |> Repo.update()
      |> tap_ok(fn updated_task ->
        Comms.broadcast_task_event(
          team_id,
          {:task_milestone, updated_task.id, updated_task.owner, milestone_name}
        )

        check_milestone_unblocks(team_id, milestone_name)
      end)
    end
  end

  @doc """
  Check if any tasks depending on the given milestone are now fully unblocked.

  Queries deps with matching `milestone_name`, then verifies if the dependent
  tasks have all their blocking deps satisfied.
  """
  def check_milestone_unblocks(team_id, milestone_name) do
    # Find task_ids that depend on this milestone
    dependent_task_ids =
      Repo.all(
        from d in TeamTaskDep,
          join: t in TeamTask,
          on: d.task_id == t.id,
          where: t.team_id == ^team_id and d.milestone_name == ^milestone_name,
          select: d.task_id,
          distinct: true
      )

    if dependent_task_ids != [] do
      blocked_ids = blocked_task_ids(team_id)

      newly_unblocked =
        dependent_task_ids
        |> Enum.reject(fn id -> id in blocked_ids end)

      if newly_unblocked != [] do
        # Gather predecessor outputs for tasks with :requires_output deps
        predecessor_outputs =
          newly_unblocked
          |> Enum.map(fn id -> {id, get_predecessor_outputs(id)} end)
          |> Enum.into(%{})

        Comms.broadcast_task_event(
          team_id,
          {:tasks_unblocked, newly_unblocked, predecessor_outputs}
        )
      end
    end
  end

  @doc """
  Detect if adding an edge from `from_id` to `to_id` would create a cycle.

  Uses a recursive CTE to walk ancestors of `to_id` looking for `from_id`.
  Returns `true` if a cycle would be created.
  """
  def detect_cycle?(from_id, to_id) do
    if from_id == to_id do
      true
    else
      detect_cycle_cte(to_id, from_id)
    end
  end

  @doc """
  Propagate priority to blocking predecessors.

  When a task's priority is raised, recursively propagate to predecessors
  that have a lower (numerically higher) priority value.
  """
  def propagate_priority(task_id, new_priority) do
    Repo.transaction(fn ->
      do_propagate_priority(task_id, new_priority, MapSet.new())
    end)
  end

  defp do_propagate_priority(task_id, new_priority, visited) do
    if MapSet.member?(visited, task_id) do
      :ok
    else
      visited = MapSet.put(visited, task_id)

      predecessors =
        Repo.all(
          from d in TeamTaskDep,
            join: dep in TeamTask,
            on: d.depends_on_id == dep.id,
            where: d.task_id == ^task_id and d.dep_type in [:blocks, :requires_output],
            select: dep
        )

      Enum.each(predecessors, fn pred ->
        if pred.priority > new_priority do
          pred
          |> TeamTask.changeset(%{priority: new_priority})
          |> Repo.update()
          |> tap_ok(fn updated ->
            Comms.broadcast_task_event(
              updated.team_id,
              {:task_priority_changed, updated.id, updated.owner, new_priority}
            )

            do_propagate_priority(updated.id, new_priority, visited)
          end)
        end
      end)
    end
  end

  def list_available(team_id) do
    pending_tasks =
      Repo.all(
        from t in TeamTask,
          where: t.team_id == ^team_id and t.status == :pending,
          order_by: [asc: t.priority, asc: t.inserted_at]
      )

    blocked_ids = blocked_task_ids(team_id)

    Enum.reject(pending_tasks, fn t -> t.id in blocked_ids end)
  end

  def list_by_agent(team_id, agent_name) do
    Repo.all(
      from t in TeamTask,
        where: t.team_id == ^team_id and t.owner == ^agent_name,
        order_by: [asc: t.priority, asc: t.inserted_at]
    )
  end

  def list_all(team_id) do
    Repo.all(
      from t in TeamTask,
        where: t.team_id == ^team_id,
        order_by: [asc: t.priority, asc: t.inserted_at]
    )
  end

  @doc "Returns {tasks, deps} tuple with all tasks and their dependency records for a team."
  def list_with_deps(team_id) do
    tasks = list_all(team_id)
    task_ids = Enum.map(tasks, & &1.id)

    deps =
      if task_ids == [] do
        []
      else
        Repo.all(
          from d in TeamTaskDep,
            where: d.task_id in ^task_ids or d.depends_on_id in ^task_ids
        )
      end

    {tasks, deps}
  end

  @doc "List tasks from sibling teams for cross-team visibility."
  def list_cross_team_tasks(team_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    case Loomkin.Teams.Manager.get_sibling_teams(team_id) do
      {:ok, siblings} ->
        siblings
        |> Enum.flat_map(fn sib_id -> list_all(sib_id) end)
        |> Enum.take(limit)

      :error ->
        []
    end
  end

  def get_task(task_id) do
    case Ecto.UUID.cast(task_id) do
      :error ->
        {:error, :not_found}

      {:ok, _} ->
        case Repo.get(TeamTask, task_id) do
          nil -> {:error, :not_found}
          task -> {:ok, task}
        end
    end
  end

  @doc """
  Smart-assign a task to the best available agent based on capabilities and load.

  Returns `{:ok, task, reasoning}` or `{:error, reason}`.
  """
  def smart_assign(team_id, task_id) do
    with {:ok, task} <- get_task(task_id),
         {:ok, agent_name, reason} <- pick_best_agent(team_id, task) do
      case assign_task(task_id, agent_name) do
        {:ok, task} ->
          Comms.broadcast(team_id, {:smart_assigned, task.id, agent_name, reason})
          {:ok, task, reason}

        error ->
          error
      end
    end
  end

  defp pick_best_agent(team_id, task) do
    agents = Context.list_agents(team_id)
    idle_agents = Enum.filter(agents, fn a -> a.status == :idle end)

    if idle_agents == [] do
      {:error, :no_idle_agents}
    else
      task_type = Capabilities.infer_task_type(task.title)
      ranked = Capabilities.best_agent_for(team_id, task_type)
      idle_names = MapSet.new(idle_agents, & &1.name)

      # Find best ranked agent that is idle
      best_capable =
        Enum.find(ranked, fn entry -> MapSet.member?(idle_names, entry.agent) end)

      case best_capable do
        %{agent: name, score: score} when score > 0 ->
          {:ok, name, "Best at #{task_type} (score: #{Float.round(score, 2)})"}

        _ ->
          # Fall back to least-loaded idle agent
          agent_loads = agent_load_counts(team_id)

          least_loaded =
            idle_agents
            |> Enum.min_by(fn a -> Map.get(agent_loads, a.name, 0) end)

          load = Map.get(agent_loads, least_loaded.name, 0)
          {:ok, least_loaded.name, "Least loaded idle agent (#{load} active tasks)"}
      end
    end
  end

  defp agent_load_counts(team_id) do
    Repo.all(
      from t in TeamTask,
        where: t.team_id == ^team_id and t.status in [:assigned, :in_progress],
        group_by: t.owner,
        select: {t.owner, count(t.id)}
    )
    |> Enum.into(%{})
  end

  # -- Speculative Execution --

  @doc """
  Start speculative execution on a task that is blocked by `blocker_task_id`.

  Marks the task as `:pending_speculative`, records the assumed output, and
  broadcasts a `TaskSpeculativeStarted` signal.
  """
  def start_speculative(task_id, blocker_task_id, assumed_output) do
    task = get_task!(task_id)

    if task.status not in [:pending, :blocked] do
      {:error, :invalid_transition}
    else
      task
      |> TeamTask.changeset(%{
        status: :pending_speculative,
        speculative: true,
        based_on_tentative: blocker_task_id,
        confidence: Decimal.new("0.5")
      })
      |> Repo.update()
      |> tap_ok(fn task ->
        record_assumption(task.id, "blocker_output", assumed_output)

        Comms.broadcast_task_event(
          task.team_id,
          {:task_speculative_started, task.id, blocker_task_id, assumed_output}
        )

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: :pending_speculative,
          owner: task.owner
        })
      end)
    end
  end

  @doc """
  Record an assumption for a speculative task.

  Stores the assumption key and assumed value in the `task_assumptions` table.
  """
  def record_assumption(task_id, assumption_key, assumed_value) do
    %TaskAssumption{}
    |> TaskAssumption.changeset(%{
      task_id: task_id,
      assumption_key: assumption_key,
      assumed_value: assumed_value
    })
    |> Repo.insert()
  end

  @doc """
  Validate assumptions for a speculative task against the actual blocker output.

  Compares each assumption's `assumed_value` against the `actual_value` (the
  blocker's result). Returns `{:ok, true}` or `{:error, mismatches}`.
  """
  def validate_assumptions(task_id) do
    task = get_task!(task_id)

    if not task.speculative do
      {:error, :not_speculative}
    else
      assumptions = Repo.all(from a in TaskAssumption, where: a.task_id == ^task_id)

      blocker_result =
        case task.based_on_tentative do
          nil -> nil
          blocker_id -> Repo.get(TeamTask, blocker_id)
        end

      actual_output = if blocker_result, do: blocker_result.result, else: nil

      mismatches =
        Enum.reduce(assumptions, [], fn assumption, acc ->
          matched = assumption.assumed_value == actual_output

          assumption
          |> TaskAssumption.changeset(%{actual_value: actual_output, matched: matched})
          |> Repo.update()

          if matched do
            acc
          else
            [
              %{
                key: assumption.assumption_key,
                assumed: assumption.assumed_value,
                actual: actual_output
              }
              | acc
            ]
          end
        end)

      if mismatches == [] do
        {:ok, true}
      else
        {:error, mismatches}
      end
    end
  end

  @doc """
  Confirm a tentative speculative task result.

  Transitions `:completed_tentative` to `:completed` and sets confidence to 1.0.
  """
  def confirm_tentative(task_id) do
    task = get_task!(task_id)

    if task.status != :completed_tentative do
      {:error, :invalid_transition}
    else
      task
      |> TeamTask.changeset(%{status: :completed, confidence: Decimal.new("1.0")})
      |> Repo.update()
      |> tap_ok(fn task ->
        Comms.broadcast_task_event(task.team_id, {:speculative_confirmed, task.id})

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: :completed,
          owner: task.owner
        })

        auto_schedule_unblocked(task.team_id)
      end)
    end
  end

  @doc """
  Discard a tentative speculative task result.

  Marks the task as `:discarded_tentative`. Optionally re-queues the task as
  `:pending` for non-speculative execution when `requeue: true` is passed.
  """
  def discard_tentative(task_id, opts \\ []) do
    task = get_task!(task_id)

    if task.status not in [:completed_tentative, :pending_speculative] do
      {:error, :invalid_transition}
    else
      Repo.transaction(fn ->
        case task
             |> TeamTask.changeset(%{status: :discarded_tentative})
             |> Repo.update() do
          {:ok, updated_task} ->
            from(a in TaskAssumption, where: a.task_id == ^task_id) |> Repo.delete_all()

            if Keyword.get(opts, :requeue, false) do
              case requeue_speculative(updated_task) do
                {:ok, requeued} -> requeued
                {:error, reason} -> Repo.rollback(reason)
              end
            else
              updated_task
            end

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> tap_ok(fn task ->
        Comms.broadcast_task_event(task.team_id, {:speculative_discarded, task.id})

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: task.status,
          owner: task.owner
        })
      end)
    end
  end

  @doc """
  Mark a speculative task as tentatively completed.

  The task remains in `:completed_tentative` until its assumptions are validated.
  """
  def complete_speculative(task_id, result) do
    task = get_task!(task_id)

    if task.status != :pending_speculative or not task.speculative do
      {:error, :invalid_transition}
    else
      task
      |> TeamTask.changeset(%{status: :completed_tentative, result: result})
      |> Repo.update()
      |> tap_ok(fn task ->
        Comms.broadcast_task_event(
          task.team_id,
          {:task_speculative_completed, task.id, task.owner, result}
        )

        Context.cache_task(task.team_id, task.id, %{
          title: task.title,
          status: :completed_tentative,
          owner: task.owner
        })
      end)
    end
  end

  # -- Private --

  defp get_task!(task_id) do
    case Ecto.UUID.cast(task_id) do
      {:ok, _} -> Repo.get!(TeamTask, task_id)
      :error -> raise Ecto.NoResultsError, queryable: TeamTask
    end
  end

  defp blocked_task_ids(team_id) do
    blocks_blocked =
      from d in TeamTaskDep,
        join: t in TeamTask,
        on: d.task_id == t.id,
        join: dep in TeamTask,
        on: d.depends_on_id == dep.id,
        where:
          t.team_id == ^team_id and d.dep_type == :blocks and
            dep.status != :completed and is_nil(d.milestone_name),
        select: d.task_id

    requires_output_blocked =
      from d in TeamTaskDep,
        join: t in TeamTask,
        on: d.task_id == t.id,
        join: dep in TeamTask,
        on: d.depends_on_id == dep.id,
        where:
          t.team_id == ^team_id and d.dep_type == :requires_output and
            dep.status not in [:completed, :partially_complete] and is_nil(d.milestone_name),
        select: d.task_id

    milestone_blocked =
      from d in TeamTaskDep,
        join: t in TeamTask,
        on: d.task_id == t.id,
        join: dep in TeamTask,
        on: d.depends_on_id == dep.id,
        where:
          t.team_id == ^team_id and not is_nil(d.milestone_name) and
            fragment(
              "? != ALL(coalesce(?, ARRAY[]::varchar[]))",
              d.milestone_name,
              dep.milestones_emitted
            ),
        select: d.task_id

    blocks_blocked
    |> union(^requires_output_blocked)
    |> union(^milestone_blocked)
    |> distinct(true)
    |> Repo.all()
  end

  defp maybe_verify_before_unblocking(task) do
    dependent_ids = get_dependent_task_ids(task.id)

    if dependent_ids == [] do
      # No dependents — unblock immediately
      auto_schedule_unblocked(task.team_id)
    else
      # Dependents exist — spawn upstream verifier before unblocking
      team_id = task.team_id

      on_complete = fn result ->
        if result.passed do
          Logger.info(
            "[Verification] passed for task=#{task.id} confidence=#{result.confidence}, unblocking dependents"
          )
        else
          Logger.warning(
            "[Verification] failed for task=#{task.id} confidence=#{result.confidence}, routing to healing"
          )

          Comms.broadcast_task_event(
            team_id,
            {:verification_failed, task.id, result}
          )

          try do
            Loomkin.Healing.Orchestrator.request_healing(team_id, task.owner || "unknown", %{
              error_type: :verification_failure,
              task_id: task.id,
              task_title: task.title,
              verification_result: result
            })
          rescue
            e ->
              Logger.warning("[Verification] could not route to healing: #{Exception.message(e)}")
          end
        end

        # Always unblock dependents — verification is advisory, not blocking.
        # Failed verification routes to healing for repair, but dependents proceed.
        auto_schedule_unblocked(team_id)
      end

      UpstreamVerifier.start(
        team_id: team_id,
        task: task,
        dependent_task_ids: dependent_ids,
        on_complete: on_complete
      )
    end
  end

  defp get_dependent_task_ids(task_id) do
    Repo.all(
      from d in TeamTaskDep,
        where: d.depends_on_id == ^task_id and d.dep_type in [:blocks, :requires_output],
        select: d.task_id
    )
  end

  defp auto_schedule_unblocked(team_id) do
    available = list_available(team_id)

    if available != [] do
      task_ids = Enum.map(available, & &1.id)

      # Gather predecessor outputs for tasks with :requires_output deps
      predecessor_outputs =
        task_ids
        |> Enum.map(fn id -> {id, get_predecessor_outputs(id)} end)
        |> Enum.reject(fn {_id, outputs} -> outputs == [] end)
        |> Enum.into(%{})

      Comms.broadcast_task_event(
        team_id,
        {:tasks_unblocked, task_ids, predecessor_outputs}
      )
    end
  end

  defp record_learning_metric(task, success?) do
    if task.owner do
      usage = CostTracker.get_agent_usage(task.team_id, task.owner)

      Learning.record_task_result(%{
        team_id: task.team_id,
        agent_name: task.owner,
        role: task.role || "unknown",
        model: usage[:model] || "unknown",
        task_type: task.task_type || task.title || "general",
        success: success?,
        cost_usd: usage.cost,
        tokens_used: (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
      })
    end
  rescue
    _ -> :ok
  end

  defp record_capability(task, outcome) do
    if task.owner do
      task_type = Capabilities.infer_task_type(task.title)
      Capabilities.record_completion(task.team_id, task.owner, task_type, outcome)
    end
  rescue
    _ -> :ok
  end

  defp detect_cycle_cte(start_id, target_id) do
    sql = """
    WITH RECURSIVE ancestors AS (
      SELECT depends_on_id FROM team_task_deps WHERE task_id = $1 AND dep_type IN ('blocks', 'requires_output')
      UNION
      SELECT d.depends_on_id FROM team_task_deps d JOIN ancestors a ON d.task_id = a.depends_on_id WHERE d.dep_type IN ('blocks', 'requires_output')
    )
    SELECT 1 FROM ancestors WHERE depends_on_id = $2 LIMIT 1
    """

    case Repo.query(sql, [Ecto.UUID.dump!(start_id), Ecto.UUID.dump!(target_id)]) do
      {:ok, %{num_rows: 0}} -> false
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp validate_speculative_dependents(task) do
    speculative_tasks =
      Repo.all(
        from t in TeamTask,
          where: t.based_on_tentative == ^task.id and t.speculative == true,
          where: t.status in [:pending_speculative, :completed_tentative]
      )

    errors =
      Enum.reduce(speculative_tasks, [], fn spec_task, acc ->
        case validate_assumptions(spec_task.id) do
          {:ok, true} ->
            if spec_task.status == :completed_tentative do
              confirm_tentative(spec_task.id)
            end

            acc

          {:error, mismatches} ->
            Enum.each(mismatches, fn m ->
              Comms.broadcast_task_event(
                spec_task.team_id,
                {:assumption_violated, spec_task.id, m.key, m.assumed, m.actual}
              )
            end)

            discard_tentative(spec_task.id, requeue: true)
            [{spec_task.id, mismatches} | acc]
        end
      end)

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  defp requeue_speculative(task) do
    task
    |> TeamTask.changeset(%{
      status: :pending,
      speculative: false,
      based_on_tentative: nil,
      confidence: Decimal.new("1.0"),
      result: nil
    })
    |> Repo.update()
    |> tap_ok(fn requeued ->
      Context.cache_task(requeued.team_id, requeued.id, %{
        title: requeued.title,
        status: :pending,
        owner: requeued.owner
      })
    end)
  end

  defp tap_ok({:ok, val} = result, fun) do
    fun.(val)
    result
  end

  defp tap_ok(error, _fun), do: error

  defp get_flexible(map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, val} -> val
      :error -> Map.get(map, string_key)
    end
  end

  defp empty_artifacts?(attrs) do
    (attrs.actions_taken || []) == [] and
      (attrs.discoveries || []) == [] and
      (attrs.files_changed || []) == []
  end
end
