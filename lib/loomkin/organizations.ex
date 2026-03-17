defmodule Loomkin.Organizations do
  @moduledoc "Context module for managing organizations and memberships."

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.Organization
  alias Loomkin.Schemas.OrganizationMembership

  @allowed_member_roles [:admin, :member]

  # --- Organization CRUD ---

  def create_organization(%{user: user}, attrs) when not is_nil(user) do
    Repo.transaction(fn ->
      with {:ok, org} <- %Organization{} |> Organization.changeset(attrs) |> Repo.insert(),
           {:ok, _membership} <-
             %OrganizationMembership{}
             |> OrganizationMembership.changeset(%{
               organization_id: org.id,
               user_id: user.id,
               role: :owner
             })
             |> Repo.insert() do
        org
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def update_organization(%{user: user}, %Organization{} = org, attrs) do
    with :ok <- authorize(org, user, [:owner, :admin]) do
      org |> Organization.changeset(attrs) |> Repo.update()
    end
  end

  def delete_organization(%{user: user}, %Organization{} = org) do
    with :ok <- authorize(org, user, [:owner]) do
      Repo.delete(org)
    end
  end

  def get_organization(id), do: Repo.get(Organization, id)

  def get_organization_by_slug(slug) do
    Repo.get_by(Organization, slug: slug)
  end

  # --- Membership ---

  def add_member(%{user: actor}, %Organization{} = org, user, role) do
    with :ok <- authorize(org, actor, [:owner, :admin]),
         :ok <- validate_assignable_role(role) do
      %OrganizationMembership{}
      |> OrganizationMembership.changeset(%{
        organization_id: org.id,
        user_id: user.id,
        role: role
      })
      |> Repo.insert()
    end
  end

  def remove_member(%{user: actor}, %Organization{} = org, user) do
    with :ok <- authorize(org, actor, [:owner, :admin]),
         :ok <- prevent_owner_removal(org, user) do
      OrganizationMembership
      |> where([m], m.organization_id == ^org.id and m.user_id == ^user.id)
      |> Repo.delete_all()

      :ok
    end
  end

  def update_member_role(%{user: actor}, %Organization{} = org, user, new_role) do
    with :ok <- authorize(org, actor, [:owner]),
         :ok <- validate_assignable_role(new_role) do
      case get_membership(org, user) do
        nil ->
          {:error, :not_found}

        membership ->
          membership
          |> OrganizationMembership.changeset(%{role: new_role})
          |> Repo.update()
      end
    end
  end

  def list_members(%Organization{} = org) do
    OrganizationMembership
    |> where([m], m.organization_id == ^org.id)
    |> preload(:user)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  def list_user_organizations(user) do
    Organization
    |> join(:inner, [o], m in OrganizationMembership,
      on: m.organization_id == o.id and m.user_id == ^user.id
    )
    |> order_by([o], asc: o.name)
    |> Repo.all()
  end

  def member_role(%Organization{} = org, user) do
    case get_membership(org, user) do
      nil -> nil
      membership -> membership.role
    end
  end

  # --- Workspace association ---

  def assign_workspace_to_org(%{user: user}, workspace, %Organization{} = org) do
    with :ok <- authorize(org, user, [:owner, :admin]) do
      workspace
      |> Ecto.Changeset.change(organization_id: org.id)
      |> Repo.update()
    end
  end

  def list_org_workspaces(%Organization{} = org) do
    Loomkin.Workspace
    |> where([w], w.organization_id == ^org.id)
    |> order_by([w], desc: w.updated_at)
    |> Repo.all()
  end

  # --- Private ---

  defp get_membership(%Organization{} = org, user) do
    OrganizationMembership
    |> where([m], m.organization_id == ^org.id and m.user_id == ^user.id)
    |> Repo.one()
  end

  defp authorize(%Organization{} = org, user, allowed_roles) do
    role = member_role(org, user)

    if role && role in allowed_roles do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp validate_assignable_role(role) when role in @allowed_member_roles, do: :ok
  defp validate_assignable_role(_role), do: {:error, :invalid_role}

  defp prevent_owner_removal(%Organization{} = org, user) do
    case member_role(org, user) do
      :owner -> {:error, :cannot_remove_owner}
      _ -> :ok
    end
  end
end
