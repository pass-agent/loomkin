defmodule Loomkin.Vault.Sources.UrlTest do
  use ExUnit.Case, async: true

  alias Loomkin.Vault.Sources.Url

  describe "fetch/2" do
    test "returns error for invalid URLs" do
      assert {:error, msg} = Url.fetch("not-a-url")
      assert msg =~ "Invalid URL"
    end

    test "returns error for URLs without scheme" do
      assert {:error, msg} = Url.fetch("example.com/page")
      assert msg =~ "Invalid URL"
    end

    test "returns error for ftp scheme" do
      assert {:error, msg} = Url.fetch("ftp://example.com/file")
      assert msg =~ "Invalid URL"
    end
  end
end
