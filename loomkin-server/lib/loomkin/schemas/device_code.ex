defmodule Loomkin.Schemas.DeviceCode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "device_codes" do
    field :device_code, :string
    field :user_code, :string
    field :client_id, :string
    field :scope, :string, default: "vault:read vault:write"
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :interval, :integer, default: 5
    field :last_polled_at, :utc_datetime

    belongs_to :user, Loomkin.Accounts.User, type: :id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(device_code user_code client_id expires_at)a
  @optional_fields ~w(scope status interval user_id last_polled_at)a
  @valid_statuses ~w(pending approved denied expired)

  def changeset(device_code, attrs) do
    device_code
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:device_code)
    |> unique_constraint(:user_code)
  end
end
