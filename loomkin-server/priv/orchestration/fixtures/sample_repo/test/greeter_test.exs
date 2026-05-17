ExUnit.start()

defmodule GreeterTest do
  use ExUnit.Case, async: true

  test "greet/1 personalises the greeting" do
    assert Greeter.greet("vincent") == "hello, vincent"
  end
end
