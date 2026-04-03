defmodule Loomkin.Kin do
  @moduledoc "Context module for managing kin agent configurations."

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.KinAgent

  def list_kin do
    KinAgent
    |> where([k], k.enabled == true)
    |> order_by([k], desc: k.potency)
    |> Repo.all()
  end

  def list_all do
    KinAgent
    |> order_by([k], desc: k.potency)
    |> Repo.all()
  end

  def list_auto_spawn do
    KinAgent
    |> where([k], k.enabled == true and k.auto_spawn == true)
    |> Repo.all()
  end

  def list_by_potency(min_potency \\ 21) do
    KinAgent
    |> where([k], k.enabled == true and k.potency >= ^min_potency)
    |> order_by([k], desc: k.potency)
    |> Repo.all()
  end

  def get_kin(id), do: Repo.get(KinAgent, id)

  @doc "Fetch an enabled kin by exact name match. Returns nil if not found or disabled."
  def get_kin_by_name(name) when is_binary(name) do
    Repo.get_by(KinAgent, name: name, enabled: true)
  end

  def create_kin(attrs) do
    %KinAgent{}
    |> KinAgent.changeset(attrs)
    |> Repo.insert()
  end

  def update_kin(%KinAgent{} = kin, attrs) do
    kin
    |> KinAgent.changeset(attrs)
    |> Repo.update()
  end

  def delete_kin(%KinAgent{} = kin) do
    Repo.delete(kin)
  end

  def toggle_enabled(%KinAgent{} = kin) do
    update_kin(kin, %{enabled: !kin.enabled})
  end
end
