defmodule Loomkin.Vault.Sources.GoogleDriveTest do
  use ExUnit.Case, async: true

  alias Loomkin.Vault.Sources.GoogleDrive

  describe "fetch/2" do
    test "returns error when no google token is configured" do
      # Without a running TokenStore or stored token, get_access_token returns nil
      assert {:error, msg} = GoogleDrive.fetch("1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms")
      assert msg =~ "Google OAuth not configured"
    end
  end
end
