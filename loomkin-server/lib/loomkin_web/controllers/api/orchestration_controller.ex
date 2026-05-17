defmodule LoomkinWeb.Api.OrchestrationController do
  @moduledoc """
  Authenticated JSON API for the orchestration framework.

  Endpoints:

    * `GET  /api/v1/orchestration/epics`            — list recent epics
    * `POST /api/v1/orchestration/epics`            — create + start an epic
    * `GET  /api/v1/orchestration/epics/:id`        — single epic with work units + gates
  """
  use LoomkinWeb, :controller

  alias Loomkin.Orchestration.{Callbacks, Context, SwarmCoordinator}

  def index(conn, _params) do
    epics = Context.list_epics(limit: 100) |> Enum.map(&summary/1)
    json(conn, %{data: epics})
  end

  def show(conn, %{"id" => id}) do
    case Context.get_epic(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})

      epic ->
        json(conn, %{
          data:
            summary(epic)
            |> Map.put(:work_units, Context.list_work_units(id) |> Enum.map(&wu_summary/1))
            |> Map.put(:gate_results, Context.list_gate_results(id) |> Enum.map(&gate_summary/1))
        })
    end
  end

  def create(conn, params) do
    case Context.create_epic(%{
           title: params["title"],
           spec: params["spec"] || "",
           priority: params["priority"] || 2
         }) do
      {:ok, epic} ->
        epic_map = %{id: epic.id, title: epic.title, spec: epic.spec}
        callbacks = Callbacks.default_issue_callbacks()
        {:ok, _pid} = SwarmCoordinator.submit(epic_map, callbacks: callbacks)
        conn |> put_status(:created) |> json(%{data: summary(epic)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_changeset(changeset)})
    end
  end

  defp summary(epic) do
    %{
      id: epic.id,
      title: epic.title,
      status: epic.status,
      current_phase: epic.current_phase,
      priority: epic.priority,
      inserted_at: epic.inserted_at
    }
  end

  defp wu_summary(wu) do
    %{
      id: wu.id,
      title: wu.title,
      status: wu.status,
      iteration: wu.iteration,
      commit_sha: wu.commit_sha
    }
  end

  defp gate_summary(g) do
    %{
      id: g.id,
      kind: g.kind,
      verdict: g.verdict,
      iteration: g.iteration,
      reviewer_count: length(g.verdicts || [])
    }
  end

  defp format_changeset(%Ecto.Changeset{errors: errors}) do
    Map.new(errors, fn {k, {msg, _}} -> {k, msg} end)
  end
end
