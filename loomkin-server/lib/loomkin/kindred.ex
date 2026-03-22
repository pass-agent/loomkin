defmodule Loomkin.Kindred do
  @moduledoc "Context module for managing kindred bundles and their items."

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.Kindred
  alias Loomkin.Schemas.KindredItem

  # --- Kindred CRUD ---

  def create_kindred(%{user: user}, attrs) when not is_nil(user) do
    attrs =
      case attrs[:owner_type] do
        :organization ->
          # Org kindred: set organization_id, do NOT set user_id
          attrs

        _ ->
          # Personal kindred: default owner_type to :user and set user_id
          attrs
          |> Map.put_new(:owner_type, :user)
          |> Map.put_new(:user_id, user.id)
      end

    %Kindred{}
    |> Kindred.changeset(attrs)
    |> Repo.insert()
  end

  def update_kindred(%{user: user}, %Kindred{} = kindred, attrs) do
    with :ok <- authorize_kindred(user, kindred) do
      kindred
      |> Kindred.changeset(attrs)
      |> Repo.update()
    end
  end

  def publish_kindred(%{user: user}, %Kindred{} = kindred) do
    with :ok <- authorize_kindred(user, kindred) do
      kindred
      |> Kindred.changeset(%{
        status: :active,
        version: kindred.version + 1
      })
      |> Repo.update()
    end
  end

  def archive_kindred(%{user: user}, %Kindred{} = kindred) do
    with :ok <- authorize_kindred(user, kindred) do
      kindred
      |> Kindred.changeset(%{status: :archived})
      |> Repo.update()
    end
  end

  def get_kindred(id), do: Repo.get(Kindred, id)

  def get_kindred!(id), do: Repo.get!(Kindred, id)

  def get_kindred_for_user!(%{user: user}, id) do
    kindred = Repo.get!(Kindred, id)

    case authorize_kindred(user, kindred) do
      :ok -> kindred
      {:error, :unauthorized} -> raise Ecto.NoResultsError, queryable: Kindred
    end
  end

  # --- Items ---

  def add_item(%{user: user}, %Kindred{} = kindred, attrs) do
    with :ok <- authorize_kindred(user, kindred) do
      max_position =
        KindredItem
        |> where([i], i.kindred_id == ^kindred.id)
        |> select([i], max(i.position))
        |> Repo.one() || -1

      attrs =
        attrs
        |> Map.put(:kindred_id, kindred.id)
        |> Map.put_new(:position, max_position + 1)

      %KindredItem{}
      |> KindredItem.changeset(attrs)
      |> Repo.insert()
    end
  end

  def remove_item(%{user: user}, %Kindred{} = kindred, item_id) do
    with :ok <- authorize_kindred(user, kindred) do
      case Repo.get(KindredItem, item_id) do
        nil -> {:error, :not_found}
        %{kindred_id: kid} = item when kid == kindred.id -> Repo.delete(item)
        _item -> {:error, :not_found}
      end
    end
  end

  def update_item(%{user: user}, %KindredItem{} = item, attrs) do
    kindred = get_kindred!(item.kindred_id)

    with :ok <- authorize_kindred(user, kindred) do
      item
      |> KindredItem.changeset(attrs)
      |> Repo.update()
    end
  end

  def list_items(%Kindred{} = kindred) do
    KindredItem
    |> where([i], i.kindred_id == ^kindred.id)
    |> order_by([i], asc: i.position)
    |> Repo.all()
  end

  # --- Listing ---

  def list_user_kindreds(user) do
    Kindred
    |> where([k], k.user_id == ^user.id)
    |> order_by([k], desc: k.updated_at)
    |> Repo.all()
  end

  def list_org_kindreds(org) do
    Kindred
    |> where([k], k.organization_id == ^org.id)
    |> order_by([k], desc: k.updated_at)
    |> Repo.all()
  end

  def active_kindred_for_org(org) do
    Kindred
    |> where([k], k.organization_id == ^org.id and k.status == :active)
    |> order_by([k], desc: k.version)
    |> limit(1)
    |> preload(:items)
    |> Repo.one()
  end

  def active_kindred_for_user(user) do
    Kindred
    |> where([k], k.user_id == ^user.id and k.status == :active)
    |> order_by([k], desc: k.version)
    |> limit(1)
    |> preload(:items)
    |> Repo.one()
  end

  # --- Authorization ---

  defp authorize_kindred(user, %Kindred{} = kindred) do
    cond do
      # User owns this kindred directly
      kindred.user_id && kindred.user_id == user.id ->
        :ok

      # Kindred belongs to an org — check membership
      kindred.organization_id ->
        role =
          Loomkin.Organizations.member_role(
            %Loomkin.Schemas.Organization{id: kindred.organization_id},
            user
          )

        if role in [:owner, :admin], do: :ok, else: {:error, :unauthorized}

      true ->
        {:error, :unauthorized}
    end
  end
end
