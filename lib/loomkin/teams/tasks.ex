defmodule Loomkin.Teams.Tasks do
  @moduledoc "CRUD + coordination logic for team tasks."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.TeamTask
  alias Loomkin.Schemas.TeamTaskDep
  alias Loomkin.Teams.Capabilities
  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.Context
  alias Loomkin.Teams.CostTracker
  alias Loomkin.Teams.Learning

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

  def assign_task(task_id, agent_name) do
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

  def complete_task(task_id, result) do
    task = get_task!(task_id)

    if task.status in [:completed, :failed] do
      {:ok, task}
    else
      task
      |> TeamTask.changeset(%{status: :completed, result: result})
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
        auto_schedule_unblocked(task.team_id)
      end)
    end
  end

  def fail_task(task_id, reason) do
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

  def add_dependency(task_id, depends_on_id, dep_type \\ :blocks) do
    %TeamTaskDep{}
    |> TeamTaskDep.changeset(%{
      task_id: task_id,
      depends_on_id: depends_on_id,
      dep_type: dep_type
    })
    |> Repo.insert()
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

  def get_task(task_id) do
    case Repo.get(TeamTask, task_id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
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

  # -- Private --

  defp get_task!(task_id) do
    Repo.get!(TeamTask, task_id)
  end

  defp blocked_task_ids(team_id) do
    Repo.all(
      from d in TeamTaskDep,
        join: t in TeamTask,
        on: d.task_id == t.id,
        join: dep in TeamTask,
        on: d.depends_on_id == dep.id,
        where: t.team_id == ^team_id and d.dep_type == :blocks and dep.status != :completed,
        select: d.task_id,
        distinct: true
    )
  end

  defp auto_schedule_unblocked(team_id) do
    available = list_available(team_id)

    if available != [] do
      Comms.broadcast_task_event(team_id, {:tasks_unblocked, Enum.map(available, & &1.id)})
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
        cost_usd: usage.cost || 0.0,
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

  defp tap_ok({:ok, val} = result, fun) do
    fun.(val)
    result
  end

  defp tap_ok(error, _fun), do: error
end
