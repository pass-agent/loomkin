defmodule Loomkin.Permissions.Hooks.MockDenyHook do
  @moduledoc false
  @behaviour Loomkin.Permissions.Hook

  @impl true
  def name, do: "mock_deny"

  @impl true
  def description, do: "Always denies"

  @impl true
  def pre_tool(_name, _args), do: :deny

  @impl true
  def post_tool(_name, _args, _result), do: {:rollback, "denied"}
end
