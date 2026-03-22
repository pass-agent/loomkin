defmodule Loomkin.Permissions.Hooks.MockAskHook do
  @moduledoc false
  @behaviour Loomkin.Permissions.Hook

  @impl true
  def name, do: "mock_ask"

  @impl true
  def description, do: "Always asks"

  @impl true
  def pre_tool(_name, _args), do: {:ask, "needs confirmation"}

  @impl true
  def post_tool(_name, _args, _result), do: :ok
end
