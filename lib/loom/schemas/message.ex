defmodule Loom.Schemas.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    belongs_to :session, Loom.Schemas.Session
    field :role, Ecto.Enum, values: [:system, :user, :assistant, :tool]
    field :content, :string
    field :tool_calls, {:array, :map}
    field :tool_call_id, :string
    field :token_count, :integer

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(session_id role)a
  @optional_fields ~w(content tool_calls tool_call_id token_count)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:session_id)
  end
end
