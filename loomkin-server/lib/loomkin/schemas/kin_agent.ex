defmodule Loomkin.Schemas.KinAgent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kin_agents" do
    field :name, :string
    field :display_name, :string

    field :role, Ecto.Enum,
      values: [:lead, :researcher, :coder, :reviewer, :tester, :concierge, :weaver]

    field :auto_spawn, :boolean, default: false
    field :potency, :integer, default: 50
    field :spawn_context, :string
    field :model_override, :string
    field :system_prompt_extra, :string
    field :tool_overrides, :map, default: %{}
    field :budget_limit, :integer
    field :tags, {:array, :string}, default: []
    field :enabled, :boolean, default: true

    belongs_to :user, Loomkin.Accounts.User

    timestamps()
  end

  @required_fields ~w(name role)a
  @optional_fields ~w(display_name auto_spawn potency spawn_context model_override system_prompt_extra tool_overrides budget_limit tags enabled user_id)a

  def changeset(kin_agent \\ %__MODULE__{}, attrs) do
    kin_agent
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:potency, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_length(:name, min: 1, max: 50)
    |> unique_constraint([:name])
  end
end
