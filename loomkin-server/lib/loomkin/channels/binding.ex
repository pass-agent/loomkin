defmodule Loomkin.Channels.Binding do
  @moduledoc """
  Ecto schema for a channel-to-team binding.

  A binding links an external channel conversation (Telegram chat_id or
  Discord channel_id) to a Loomkin team, enabling bidirectional communication.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channel_bindings" do
    field :channel, Ecto.Enum, values: [:telegram, :discord]
    field :channel_id, :string
    field :team_id, :string
    field :user_id, :string
    field :config, :map, default: %{}
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(channel channel_id team_id)a
  @optional_fields ~w(user_id config active)a

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:channel, :channel_id],
      name: :channel_bindings_channel_channel_id_index
    )
  end
end
