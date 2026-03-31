defmodule Loomkin.Collaboration do
  @moduledoc """
  Context for workspace sharing and collaboration.

  Manages the invite lifecycle (create, accept, decline, revoke) and
  workspace membership (roles, authorization, removal). Each workspace
  has exactly one owner; collaborators and observers are added via invites.
  """

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Workspace
  alias Loomkin.Schemas.WorkspaceInvite
  alias Loomkin.Schemas.WorkspaceMembership

  # --- Invite Flow ---

  @doc """
  Create an invitation for someone to join a workspace.

  The caller must be the workspace owner. A pending invite for the same
  email+workspace pair is rejected as a duplicate.

  Returns `{:ok, invite}` or `{:error, reason}`.
  """
  def create_invite(%{user: user}, workspace_id, attrs) when not is_nil(user) do
    with {:ok, workspace} <- get_workspace(workspace_id),
         :ok <- require_owner(workspace, user),
         :ok <- check_no_duplicate_pending_invite(workspace_id, attrs) do
      %WorkspaceInvite{}
      |> WorkspaceInvite.changeset(attrs)
      |> Ecto.Changeset.put_change(:workspace_id, workspace_id)
      |> Ecto.Changeset.put_change(:invited_by_id, user.id)
      |> Repo.insert()
    end
  end

  def create_invite(_scope, _workspace_id, _attrs), do: {:error, :unauthenticated}

  @doc """
  Accept an invite by its token. Creates a workspace membership.

  The invite must be pending and not expired. Returns `{:ok, membership}`.
  """
  def accept_invite(token) when is_binary(token) do
    Repo.transaction(fn ->
      with {:ok, invite} <- get_pending_invite(token),
           :ok <- check_not_expired(invite),
           {:ok, user} <- resolve_invite_user_or_error(invite),
           :ok <- check_no_existing_membership(invite.workspace_id, user),
           {:ok, membership} <- insert_membership_from_invite(invite, user),
           {:ok, _invite} <- mark_invite_accepted(invite) do
        membership
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def accept_invite(_), do: {:error, :invalid_token}

  @doc """
  Decline an invite by its token.

  The invite must be pending. Returns `{:ok, invite}`.
  """
  def decline_invite(token) when is_binary(token) do
    with {:ok, invite} <- get_pending_invite(token) do
      invite
      |> Ecto.Changeset.change(status: :declined)
      |> Repo.update()
    end
  end

  def decline_invite(_), do: {:error, :invalid_token}

  @doc """
  Revoke an invite. Only the workspace owner can revoke.
  """
  def revoke_invite(%{user: user}, invite_id) when not is_nil(user) do
    with {:ok, invite} <- get_invite(invite_id),
         :ok <- require_pending(invite),
         {:ok, workspace} <- get_workspace(invite.workspace_id),
         :ok <- require_owner(workspace, user) do
      invite
      |> Ecto.Changeset.change(status: :revoked)
      |> Repo.update()
    end
  end

  def revoke_invite(_scope, _invite_id), do: {:error, :unauthenticated}

  @doc """
  List pending invites for a workspace.

  Requires `:manage_members` authorization.
  """
  def list_pending_invites(%{user: user}, workspace_id) when not is_nil(user) do
    with :ok <- authorize(user.id, workspace_id, :manage_members) do
      invites =
        WorkspaceInvite
        |> where([i], i.workspace_id == ^workspace_id and i.status == :pending)
        |> order_by([i], asc: i.inserted_at)
        |> Repo.all()

      {:ok, invites}
    end
  end

  def list_pending_invites(_scope, _workspace_id), do: {:error, :unauthenticated}

  # --- Membership Management ---

  @doc """
  List all members of a workspace with their user data preloaded.

  Requires `:view` authorization.
  """
  def list_members(%{user: user}, workspace_id) when not is_nil(user) do
    with :ok <- authorize(user.id, workspace_id, :view) do
      members =
        WorkspaceMembership
        |> where([m], m.workspace_id == ^workspace_id)
        |> preload(:user)
        |> order_by([m], asc: m.inserted_at)
        |> Repo.all()

      {:ok, members}
    end
  end

  def list_members(_scope, _workspace_id), do: {:error, :unauthenticated}

  @doc """
  Get a specific membership for a workspace+user pair.

  Returns `nil` if no membership exists.
  """
  def get_membership(workspace_id, user_id) do
    WorkspaceMembership
    |> where([m], m.workspace_id == ^workspace_id and m.user_id == ^user_id)
    |> Repo.one()
  end

  @doc """
  Update a member's role. Only the workspace owner can do this.

  The owner's own role cannot be changed.
  """
  def update_member_role(%{user: actor}, membership_id, new_role) when not is_nil(actor) do
    with {:ok, membership} <- get_membership_by_id(membership_id),
         {:ok, workspace} <- get_workspace(membership.workspace_id),
         :ok <- require_owner(workspace, actor),
         :ok <- prevent_owner_role_change(membership) do
      membership
      |> WorkspaceMembership.changeset(%{role: new_role})
      |> Repo.update()
    end
  end

  def update_member_role(_scope, _membership_id, _role), do: {:error, :unauthenticated}

  @doc """
  Remove a member from a workspace.

  The workspace owner can remove anyone except themselves.
  A non-owner member can remove only themselves (leave).
  """
  def remove_member(%{user: actor}, membership_id) when not is_nil(actor) do
    with {:ok, membership} <- get_membership_by_id(membership_id) do
      cond do
        # Owner cannot be removed
        membership.role == :owner ->
          {:error, :cannot_remove_owner}

        # Members can leave (remove themselves)
        membership.user_id == actor.id ->
          Repo.delete(membership)

        # Authorized users (owner role) can remove others
        authorize(actor.id, membership.workspace_id, :manage_members) == :ok ->
          Repo.delete(membership)

        true ->
          {:error, :unauthorized}
      end
    end
  end

  def remove_member(_scope, _membership_id), do: {:error, :unauthenticated}

  @doc """
  Create a workspace and its owner membership atomically.

  Wraps workspace creation and owner membership insertion in a single
  transaction so the owner always has a membership row.

  Returns `{:ok, %{workspace: workspace, membership: membership}}` or
  `{:error, failed_step, changeset, changes}`.
  """
  def create_workspace_with_owner(workspace_attrs, user_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :workspace,
      Workspace.changeset(%Workspace{}, Map.put(workspace_attrs, :user_id, user_id))
    )
    |> Ecto.Multi.insert(:membership, fn %{workspace: workspace} ->
      %WorkspaceMembership{}
      |> WorkspaceMembership.changeset(%{
        role: :owner,
        accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Ecto.Changeset.put_change(:workspace_id, workspace.id)
      |> Ecto.Changeset.put_change(:user_id, user_id)
    end)
    |> Repo.transaction()
  end

  @doc """
  Create the initial owner membership when a workspace is created.

  This is called internally, not via invite flow. Prefer
  `create_workspace_with_owner/2` for new workspace creation to ensure
  atomicity.
  """
  def create_owner_membership(workspace_id, user_id) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      role: :owner,
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Ecto.Changeset.put_change(:workspace_id, workspace_id)
    |> Ecto.Changeset.put_change(:user_id, user_id)
    |> Repo.insert()
  end

  # --- Authorization ---

  @doc """
  Check if a user is authorized to perform an action on a workspace.

  Actions and required roles:
    * `:view` — owner, collaborator, observer
    * `:send_message` — owner, collaborator
    * `:approve_tool` — owner, collaborator
    * `:manage_agents` — owner, collaborator
    * `:manage_members` — owner
    * `:delete_workspace` — owner

  Returns `:ok` or `{:error, :unauthorized}`.
  """
  def authorize(user_id, workspace_id, action) do
    case get_membership(workspace_id, user_id) do
      nil ->
        {:error, :unauthorized}

      membership ->
        if role_allows?(membership.role, action) do
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Check whether a user is a member of a workspace.
  """
  def member?(user_id, workspace_id) do
    case authorize(user_id, workspace_id, :view) do
      :ok -> true
      _ -> false
    end
  end

  # --- Private Helpers ---

  defp role_allows?(role, action) do
    case {role, action} do
      # Owners can do everything
      {:owner, _} -> true
      # Collaborators can view, send messages, approve tools, manage agents
      {:collaborator, :view} -> true
      {:collaborator, :send_message} -> true
      {:collaborator, :approve_tool} -> true
      {:collaborator, :manage_agents} -> true
      {:collaborator, :manage_members} -> false
      {:collaborator, :delete_workspace} -> false
      # Observers can only view
      {:observer, :view} -> true
      {:observer, _} -> false
      # Default deny
      _ -> false
    end
  end

  defp get_workspace(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      nil -> {:error, :workspace_not_found}
      workspace -> {:ok, workspace}
    end
  end

  defp get_invite(invite_id) do
    case Repo.get(WorkspaceInvite, invite_id) do
      nil -> {:error, :invite_not_found}
      invite -> {:ok, invite}
    end
  end

  defp get_pending_invite(token) do
    case Repo.get_by(WorkspaceInvite, token: token, status: :pending) do
      nil -> {:error, :invite_not_found}
      invite -> {:ok, invite}
    end
  end

  defp get_membership_by_id(membership_id) do
    case Repo.get(WorkspaceMembership, membership_id) do
      nil -> {:error, :membership_not_found}
      membership -> {:ok, membership}
    end
  end

  defp require_owner(%Workspace{user_id: owner_id}, %{id: actor_id})
       when owner_id == actor_id do
    :ok
  end

  defp require_owner(_workspace, _user), do: {:error, :unauthorized}

  defp require_pending(%WorkspaceInvite{status: :pending}), do: :ok
  defp require_pending(%WorkspaceInvite{}), do: {:error, :invite_not_pending}

  defp prevent_owner_role_change(%WorkspaceMembership{role: :owner}),
    do: {:error, :cannot_change_owner_role}

  defp prevent_owner_role_change(_membership), do: :ok

  defp check_not_expired(%WorkspaceInvite{expires_at: expires_at}) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      :ok
    else
      {:error, :invite_expired}
    end
  end

  defp check_no_duplicate_pending_invite(workspace_id, %{email: email})
       when is_binary(email) and byte_size(email) > 0 do
    existing =
      WorkspaceInvite
      |> where(
        [i],
        i.workspace_id == ^workspace_id and i.email == ^email and i.status == :pending
      )
      |> Repo.one()

    if existing do
      {:error, :duplicate_invite}
    else
      :ok
    end
  end

  defp check_no_duplicate_pending_invite(_workspace_id, _attrs), do: {:error, :email_required}

  defp check_no_existing_membership(workspace_id, user) do
    case get_membership(workspace_id, user.id) do
      nil -> :ok
      _membership -> {:error, :already_a_member}
    end
  end

  defp resolve_invite_user(%WorkspaceInvite{email: email}) do
    Loomkin.Accounts.get_user_by_email(email)
  end

  defp resolve_invite_user_or_error(invite) do
    case resolve_invite_user(invite) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp insert_membership_from_invite(invite, user) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      role: invite.role,
      invited_by_id: invite.invited_by_id,
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Ecto.Changeset.put_change(:workspace_id, invite.workspace_id)
    |> Ecto.Changeset.put_change(:user_id, user.id)
    |> Repo.insert()
  end

  defp mark_invite_accepted(invite) do
    invite
    |> Ecto.Changeset.change(status: :accepted)
    |> Repo.update()
  end
end
