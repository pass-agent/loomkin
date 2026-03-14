defmodule Loomkin.Auth.Providers.GoogleTest do
  use ExUnit.Case, async: false

  alias Loomkin.Auth.Providers.Google

  setup do
    original_auth = Loomkin.Config.get(:auth)
    Loomkin.Config.put(:auth, Loomkin.Config.defaults()[:auth])
    on_exit(fn -> if original_auth, do: Loomkin.Config.put(:auth, original_auth) end)
    :ok
  end

  test "provider_name/0 returns :google" do
    assert :google == Google.provider_name()
  end

  test "display_name/0 returns human-readable name" do
    assert "Google" == Google.display_name()
  end

  test "authorize_url/0 returns Google's OAuth2 v2 auth URL" do
    assert "https://accounts.google.com/o/oauth2/v2/auth" == Google.authorize_url()
  end

  test "token_url/0 returns Google's token endpoint" do
    assert "https://oauth2.googleapis.com/token" == Google.token_url()
  end

  test "supports_refresh?/0 returns true" do
    assert Google.supports_refresh?()
  end

  describe "scopes/0" do
    test "includes cloud-platform scope" do
      assert Enum.any?(Google.scopes(), &String.contains?(&1, "cloud-platform"))
    end
  end

  # client_id/0 and client_secret/0 depend on runtime TOML config.
  # Without a config fixture they return nil, which is the expected default.

  test "client_id/0 returns nil when not configured" do
    assert nil == Google.client_id()
  end

  test "client_secret/0 returns nil when not configured" do
    assert nil == Google.client_secret()
  end
end
