defmodule Loomkin.Tools.FetchContentTest do
  use ExUnit.Case, async: true

  alias Loomkin.Tools.FetchContent

  describe "run/2" do
    test "returns error for unknown source" do
      params = %{source: "unknown", identifier: "test"}
      assert {:error, msg} = FetchContent.run(params, %{})
      assert msg =~ "Unknown source"
      assert msg =~ "url"
      assert msg =~ "google_drive"
    end

    test "returns error for invalid url" do
      params = %{source: "url", identifier: "not-a-url"}
      assert {:error, msg} = FetchContent.run(params, %{})
      assert msg =~ "Invalid URL"
    end
  end
end
