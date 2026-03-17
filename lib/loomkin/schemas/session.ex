defmodule Loomkin.Schemas.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field :title, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :model, :string
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :cost_usd, :decimal, default: Decimal.new("0")
    field :summary_message_id, :binary_id
    field :project_path, :string
    field :fast_model, :string
    field :team_id, :string
    field :bootstrap_spawned, :boolean, default: false

    belongs_to :user, Loomkin.Accounts.User
    belongs_to :workspace, Loomkin.Workspace
    has_many :messages, Loomkin.Schemas.Message

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(model project_path)a
  @optional_fields ~w(title status prompt_tokens completion_tokens cost_usd summary_message_id fast_model team_id bootstrap_spawned user_id workspace_id)a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
