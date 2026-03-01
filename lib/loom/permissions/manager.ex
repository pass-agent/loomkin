defmodule Loom.Permissions.Manager do
  @moduledoc """
  Manages tool permission checks and grants.

  Tools are categorized as :read, :write, or :execute.
  Auto-approved tools (from config) are always allowed.
  Other tools require explicit grants or user confirmation.
  """

  import Ecto.Query
  alias Loom.Repo
  alias Loom.Schemas.PermissionGrant

  @read_tools ~w(file_read file_search content_search directory_list decision_query sub_agent lsp_diagnostics)
  @write_tools ~w(file_write file_edit decision_log)
  @execute_tools ~w(shell git)

  @doc """
  Check whether a tool invocation is allowed.

  Returns `:allowed`, `:denied`, or `:ask`.
  """
  def check(tool_name, path, session_id) do
    cond do
      is_auto_approved?(tool_name) ->
        :allowed

      has_grant?(tool_name, path, session_id) ->
        :allowed

      tool_category(tool_name) == :read ->
        # Read-only tools are safe to auto-approve without user confirmation
        grant(tool_name, path, session_id)
        :allowed

      true ->
        :ask
    end
  end

  @doc """
  Store a permission grant for a tool in the given scope and session.
  """
  def grant(tool_name, scope, session_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %PermissionGrant{}
    |> PermissionGrant.changeset(%{
      tool: tool_name,
      scope: scope,
      session_id: session_id,
      granted_at: now
    })
    |> Repo.insert()
  end

  @doc """
  Check if a tool is in the auto_approve list from config.
  """
  def is_auto_approved?(tool_name) do
    auto_list = Loom.Config.get(:permissions, :auto_approve) || []
    tool_name in auto_list
  end

  @doc """
  Return the category of a tool: `:read`, `:write`, or `:execute`.
  """
  def tool_category(tool_name) do
    cond do
      tool_name in @read_tools -> :read
      tool_name in @write_tools -> :write
      tool_name in @execute_tools -> :execute
      true -> :unknown
    end
  end

  # --- Private ---

  defp has_grant?(tool_name, path, session_id) do
    query =
      from g in PermissionGrant,
        where: g.session_id == ^session_id,
        where: g.tool == ^tool_name,
        where: g.scope == "*" or g.scope == ^path,
        limit: 1

    Repo.exists?(query)
  end
end
