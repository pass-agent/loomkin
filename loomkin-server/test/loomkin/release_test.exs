defmodule Loomkin.ReleaseTest do
  use ExUnit.Case, async: true

  describe "release config" do
    test "mix.exs defines loom release" do
      releases = Loomkin.MixProject.project()[:releases]
      assert releases != nil
      assert Keyword.has_key?(releases, :loomkin)

      loom_release = releases[:loomkin]
      assert :assemble in loom_release[:steps]
    end
  end
end
