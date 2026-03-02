defmodule LoomkinTest do
  use ExUnit.Case, async: true

  test "version is defined" do
    assert Loomkin.version() != nil
  end
end
