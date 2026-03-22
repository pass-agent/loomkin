defmodule Loomkin.Schemas.Follow do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "follows" do
    belongs_to :follower, Loomkin.Accounts.User, type: :id
    belongs_to :followed, Loomkin.Accounts.User, type: :id

    timestamps(type: :utc_datetime)
  end

  def changeset(follow, attrs) do
    follow
    |> cast(attrs, [])
    |> unique_constraint([:follower_id, :followed_id])
  end

  def validate_not_self_follow(changeset) do
    follower_id = get_field(changeset, :follower_id)
    followed_id = get_field(changeset, :followed_id)

    if follower_id && followed_id && follower_id == followed_id do
      add_error(changeset, :followed_id, "cannot follow yourself")
    else
      changeset
    end
  end
end
