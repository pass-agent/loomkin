defmodule Loomkin.Permissions.Hooks.MockAllowHook do
  @moduledoc false
  @behaviour Loomkin.Permissions.Hook

  @impl true
  def name, do: "mock_allow"

  @impl true
  def description, do: "Always allows"

  @impl true
  def pre_tool(_name, _args), do: :allow

  @impl true
  def post_tool(_name, _args, _result), do: :ok
end
