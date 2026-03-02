defmodule Loomkin.DataCase do
  @moduledoc """
  Test case for modules that require database access.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Loomkin.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Loomkin.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Loomkin.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
