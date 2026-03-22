defmodule Loomkin.Permissions.Hooks.MockPreOnlyHook do
  @moduledoc false
  @behaviour Loomkin.Permissions.Hook

  @impl true
  def name, do: "mock_pre_only"

  @impl true
  def description, do: "Only implements pre_tool"

  @impl true
  def pre_tool(_name, _args), do: :allow
end
