defmodule Loomkin.Permissions.Manager do
  @moduledoc """
  Manages tool permission checks and grants.

  Tools are categorized as :read, :write, or :execute.
  Auto-approved tools (from config) are always allowed.
  Other tools require explicit grants or user confirmation.
  """

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.PermissionAuditLog
  alias Loomkin.Schemas.PermissionGrant

  @read_tools ~w(file_read file_search content_search directory_list decision_query sub_agent lsp_diagnostics)
  @write_tools ~w(file_write file_edit decision_log)
  @execute_tools ~w(shell git)
  @coordination_tools ~w(team_spawn team_assign team_progress team_dissolve
    peer_message peer_discovery peer_claim_region peer_review peer_create_task
    peer_ask_question peer_answer_question peer_forward_question peer_change_role
    context_retrieve context_offload search_keepers)

  @doc """
  Check whether a tool invocation is allowed.

  Returns `:allowed`, `:denied`, or `:ask`.
  """
  def check(tool_name, path, session_id) do
    cond do
      auto_approved?(tool_name) ->
        :allowed

      has_grant?(tool_name, path, session_id) ->
        :allowed

      tool_category(tool_name) in [:read, :coordination] ->
        # Read-only and coordination tools are safe to auto-approve without user confirmation
        grant(tool_name, path, session_id)
        :allowed

      true ->
        :ask
    end
  end

  @doc """
  Boundary-aware permission check. For read tools accessing paths outside
  the project directory, requires explicit user permission instead of
  auto-approving.

  Returns `:allowed` or `:ask`.
  """
  def check(tool_name, path, session_id, project_path) when is_binary(project_path) do
    resolved = Loomkin.Tool.resolve_path(path, project_path)

    if tool_category(tool_name) in [:read] and
         Loomkin.Tool.outside_project?(resolved, project_path) do
      # Out-of-project read — check for an existing scoped grant
      if has_grant?(tool_name, resolved, session_id) do
        :allowed
      else
        :ask
      end
    else
      # In-project or non-read tool — delegate to standard check
      check(tool_name, path, session_id)
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
  def auto_approved?(tool_name) do
    auto_list = Loomkin.Config.get(:permissions, :auto_approve) || []
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
      tool_name in @coordination_tools -> :coordination
      true -> :unknown
    end
  end

  @doc """
  Record a permission decision to the audit log.
  """
  def record_decision(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %PermissionAuditLog{}
    |> PermissionAuditLog.changeset(Map.put_new(attrs, :decided_at, now))
    |> Repo.insert()
  end

  @doc """
  List recent permission decisions for a session.
  """
  def list_recent_decisions(session_id, limit \\ 20) do
    from(l in PermissionAuditLog,
      where: l.session_id == ^session_id,
      order_by: [desc: l.decided_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  # --- Private ---

  defp has_grant?(tool_name, path, session_id) do
    # Check for exact match, wildcard, or directory-prefix grants.
    # Directory-prefix grants are stored as "/path/to/dir/" (trailing slash)
    # and match any path under that directory.
    exact_query =
      from g in PermissionGrant,
        where: g.session_id == ^session_id,
        where: g.tool == ^tool_name,
        where: g.scope == "*" or g.scope == ^path,
        limit: 1

    if Repo.exists?(exact_query) do
      true
    else
      # Check directory-prefix grants — scope ends with "/" and path starts with it
      prefix_query =
        from g in PermissionGrant,
          where: g.session_id == ^session_id,
          where: g.tool == ^tool_name,
          where: fragment("? LIKE '%/' AND ? LIKE ? || '%'", g.scope, ^path, g.scope),
          limit: 1

      Repo.exists?(prefix_query)
    end
  end
end
