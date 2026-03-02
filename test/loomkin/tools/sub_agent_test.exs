defmodule Loomkin.Tools.SubAgentTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.SubAgent

  test "action metadata is correct" do
    assert SubAgent.name() == "sub_agent"
    assert is_binary(SubAgent.description())
  end
end
