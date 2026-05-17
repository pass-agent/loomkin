defmodule Loomkin.Orchestration.Context do
  @moduledoc """
  Read-side context functions for the orchestration LiveViews and CLI.

  Writes go through `SwarmCoordinator` / `IssueOrchestrator`; this module is
  only for queries.
  """

  alias Loomkin.Orchestration.Schema.{Epic, GateResult, WorkUnit}
  alias Loomkin.Repo

  import Ecto.Query, only: [from: 2]

  @doc "List recent epics, newest first."
  @spec list_epics(keyword()) :: [Epic.t()]
  def list_epics(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in Epic, order_by: [desc: e.inserted_at], limit: ^limit)
    |> Repo.all()
  end

  @spec get_epic!(binary()) :: Epic.t()
  def get_epic!(id), do: Repo.get!(Epic, id)

  @spec get_epic(binary()) :: Epic.t() | nil
  def get_epic(id), do: Repo.get(Epic, id)

  @spec list_work_units(binary()) :: [WorkUnit.t()]
  def list_work_units(epic_id) do
    from(w in WorkUnit, where: w.epic_id == ^epic_id, order_by: [asc: w.inserted_at])
    |> Repo.all()
  end

  @spec list_gate_results(binary()) :: [GateResult.t()]
  def list_gate_results(epic_id) do
    from(g in GateResult, where: g.epic_id == ^epic_id, order_by: [asc: g.inserted_at])
    |> Repo.all()
  end

  @doc "Insert an Epic row from a plain attrs map."
  @spec create_epic(map()) :: {:ok, Epic.t()} | {:error, Ecto.Changeset.t()}
  def create_epic(attrs) do
    id = Map.get(attrs, "id") || Map.get(attrs, :id) || Ecto.UUID.generate()

    %Epic{}
    |> Epic.changeset(Map.put(attrs, :id, id))
    |> Repo.insert()
  end
end
