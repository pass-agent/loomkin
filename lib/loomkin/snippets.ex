defmodule Loomkin.Snippets do
  @moduledoc "Context module for snippet queries."

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.Snippet

  @doc "List reflection report snippets for a workspace, optionally scoped to a user."
  @spec list_reflection_reports(String.t() | nil, map() | nil) :: [Snippet.t()]
  def list_reflection_reports(nil, _user), do: []

  def list_reflection_reports(workspace_id, user) do
    query =
      from(s in Snippet,
        where: s.type == :reflection_report,
        where: fragment("?->>'workspace_id' = ?", s.content, ^workspace_id),
        order_by: [desc: s.inserted_at],
        limit: 10
      )

    query =
      if user do
        where(query, [s], s.user_id == ^user.id)
      else
        query
      end

    Repo.all(query)
  rescue
    _ -> []
  end
end
