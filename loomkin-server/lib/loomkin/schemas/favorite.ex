defmodule Loomkin.Schemas.Favorite do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "favorites" do
    belongs_to :user, Loomkin.Accounts.User, type: :id
    belongs_to :snippet, Loomkin.Schemas.Snippet, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(favorite, attrs) do
    favorite
    |> cast(attrs, [])
    |> unique_constraint([:user_id, :snippet_id])
  end
end
