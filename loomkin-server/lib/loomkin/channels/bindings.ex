defmodule Loomkin.Channels.Bindings do
  @moduledoc """
  Context module for managing channel-to-team bindings.
  """

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Channels.Binding

  @doc "Create a new binding."
  @spec create_binding(map()) :: {:ok, Binding.t()} | {:error, Ecto.Changeset.t()}
  def create_binding(attrs) do
    %Binding{}
    |> Binding.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Get a binding by ID."
  @spec get_binding(String.t()) :: Binding.t() | nil
  def get_binding(id), do: Repo.get(Binding, id)

  @doc "Look up a binding by channel type and channel_id."
  @spec get_by_channel(atom(), String.t()) :: Binding.t() | nil
  def get_by_channel(channel, channel_id) do
    Repo.one(
      from b in Binding,
        where: b.channel == ^channel and b.channel_id == ^channel_id and b.active == true
    )
  end

  @doc "List all active bindings for a team."
  @spec list_bindings_for_team(String.t()) :: [Binding.t()]
  def list_bindings_for_team(team_id) do
    Repo.all(
      from b in Binding,
        where: b.team_id == ^team_id and b.active == true,
        order_by: [asc: b.inserted_at]
    )
  end

  @doc "Deactivate a binding (soft delete)."
  @spec deactivate_binding(Binding.t()) :: {:ok, Binding.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_binding(%Binding{} = binding) do
    binding
    |> Binding.changeset(%{active: false})
    |> Repo.update()
  end

  @doc """
  Find an existing active binding or create one.

  Looks up by `{channel, channel_id}`. If found and active, returns it.
  Otherwise creates a new binding with the given `team_id`.
  """
  @spec find_or_create(atom(), String.t(), String.t()) ::
          {:ok, Binding.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create(channel, channel_id, team_id) do
    case get_by_channel(channel, channel_id) do
      %Binding{} = binding ->
        {:ok, binding}

      nil ->
        # Check for an inactive binding to reactivate (avoids unique constraint violation)
        case get_inactive_by_channel(channel, channel_id) do
          %Binding{} = inactive ->
            inactive
            |> Binding.changeset(%{active: true, team_id: team_id})
            |> Repo.update()

          nil ->
            create_binding(%{channel: channel, channel_id: channel_id, team_id: team_id})
        end
    end
  end

  @doc false
  def get_inactive_by_channel(channel, channel_id) do
    Repo.one(
      from b in Binding,
        where: b.channel == ^channel and b.channel_id == ^channel_id and b.active == false,
        limit: 1
    )
  end
end
