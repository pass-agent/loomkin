defmodule Loomkin.Permissions.Hooks.MockWarnHook do
  @moduledoc false
  @behaviour Loomkin.Permissions.Hook

  @impl true
  def name, do: "mock_warn"

  @impl true
  def description, do: "Always warns"

  @impl true
  def post_tool(_name, _args, _result), do: {:warn, "something looks off"}
end
