defmodule LoomkinWeb.Api.BacklogController do
  use LoomkinWeb, :controller

  alias Loomkin.Backlog

  action_fallback LoomkinWeb.Api.FallbackController

  @doc "GET /api/v1/backlog"
  def index(conn, params) do
    items =
      case params["status"] do
        nil ->
          Backlog.list_actionable(limit: parse_limit(params["limit"]))

        status ->
          Backlog.list_by_status(String.to_existing_atom(status),
            limit: parse_limit(params["limit"])
          )
      end

    json(conn, %{items: Enum.map(items, &serialize_item/1)})
  end

  @doc "POST /api/v1/backlog"
  def create(conn, %{"item" => params}) do
    case Backlog.create_item(params) do
      {:ok, item} ->
        conn
        |> put_status(:created)
        |> json(%{item: serialize_item(item)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "GET /api/v1/backlog/:id"
  def show(conn, %{"id" => id}) do
    case Backlog.get_item(id) do
      {:ok, item} -> json(conn, %{item: serialize_item(item)})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "PUT /api/v1/backlog/:id"
  def update(conn, %{"id" => id, "item" => params}) do
    case Backlog.update_item(id, params) do
      {:ok, item} -> json(conn, %{item: serialize_item(item)})
      {:error, :not_found} -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "DELETE /api/v1/backlog/:id"
  def delete(conn, %{"id" => id}) do
    case Backlog.delete_item(id) do
      {:ok, _item} -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp serialize_item(item) do
    %{
      id: item.id,
      title: item.title,
      description: item.description,
      status: item.status,
      priority: item.priority,
      category: item.category,
      epic: item.epic,
      tags: item.tags,
      created_by: item.created_by,
      assigned_to: item.assigned_to,
      assigned_team: item.assigned_team,
      acceptance_criteria: item.acceptance_criteria,
      result: item.result,
      scope_estimate: item.scope_estimate,
      sort_order: item.sort_order,
      inserted_at: item.inserted_at,
      updated_at: item.updated_at
    }
  end

  defp parse_limit(nil), do: 50
  defp parse_limit(str) when is_binary(str), do: String.to_integer(str)
  defp parse_limit(n) when is_integer(n), do: n
end
