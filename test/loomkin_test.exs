defmodule LoomkinTest do
  use ExUnit.Case, async: true

  test "version is defined" do
    assert is_binary(Loomkin.version())
  end
end
