defmodule Loomkin.Auth.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Loomkin.Auth.Providers.OpenAI

  test "provider_name/0 returns :openai" do
    assert :openai == OpenAI.provider_name()
  end

  test "display_name/0 returns human-readable name" do
    assert "OpenAI" == OpenAI.display_name()
  end

  test "authorize_url/0 returns OpenAI's auth endpoint" do
    assert "https://auth.openai.com/oauth/authorize" == OpenAI.authorize_url()
  end

  test "token_url/0 returns OpenAI's token endpoint" do
    assert "https://auth.openai.com/oauth/token" == OpenAI.token_url()
  end

  test "client_id/0 returns the default Codex CLI client ID" do
    assert "app_EMoamEEZ73f0CkXaXp7hrann" == OpenAI.client_id()
  end

  test "supports_refresh?/0 returns true (OpenAI rotates refresh tokens)" do
    assert OpenAI.supports_refresh?()
  end

  describe "scopes/0" do
    test "includes required scopes for Codex flow" do
      scopes = OpenAI.scopes()
      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      assert "offline_access" in scopes
    end
  end

  describe "build_authorize_url/1" do
    setup do
      params = %{
        state: "test_state_abc123",
        code_verifier: "test_verifier_abcdefghijklmnop1234567890abcdef",
        redirect_uri: "http://localhost:4000/auth/openai/callback"
      }

      %{params: params}
    end

    test "includes all standard OAuth2 query parameters", %{params: params} do
      {:ok, url} = OpenAI.build_authorize_url(params)
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert query["response_type"] == "code"
      assert query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann"
      assert query["redirect_uri"] == "http://localhost:4000/auth/openai/callback"
      assert query["code_challenge_method"] == "S256"
      assert query["state"] == "test_state_abc123"
      assert query["scope"] != nil
      assert query["code_challenge"] != nil
    end

    test "includes Codex-specific parameters", %{params: params} do
      {:ok, url} = OpenAI.build_authorize_url(params)

      query =
        url
        |> URI.parse()
        |> Map.get(:query)
        |> URI.decode_query()

      assert query["id_token_add_organizations"] == "true"
      assert query["codex_cli_simplified_flow"] == "true"
      assert query["originator"] == "codex_cli_rs"
    end

    test "code_challenge is derived from code_verifier (S256)", %{params: params} do
      {:ok, url} = OpenAI.build_authorize_url(params)
      query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      expected_challenge =
        :crypto.hash(:sha256, params.code_verifier)
        |> Base.url_encode64(padding: false)

      assert query["code_challenge"] == expected_challenge
    end

    test "scope joins all default scopes with space", %{params: params} do
      {:ok, url} = OpenAI.build_authorize_url(params)

      query =
        url
        |> URI.parse()
        |> Map.get(:query)
        |> URI.decode_query()

      scope_parts = String.split(query["scope"], " ")

      for s <- ["openid", "profile", "email", "offline_access"] do
        assert s in scope_parts
      end
    end

    test "uses the correct base URL", %{params: params} do
      {:ok, url} = OpenAI.build_authorize_url(params)
      uri = URI.parse(url)

      assert uri.scheme == "https"
      assert uri.host == "auth.openai.com"
      assert uri.path == "/oauth/authorize"
    end
  end

  describe "decode_jwt_claims/1" do
    test "returns nil for nil input" do
      assert nil == OpenAI.decode_jwt_claims(nil)
    end

    test "decodes a valid JWT payload" do
      claims = %{"sub" => "user_123", "name" => "Test User"}
      assert claims == OpenAI.decode_jwt_claims(build_test_jwt(claims))
    end

    test "decodes JWT with OpenAI auth claims" do
      claims = %{
        "https://api.openai.com/auth" => %{
          "chatgpt_account_id" => "acct_test_12345"
        }
      }

      assert claims == OpenAI.decode_jwt_claims(build_test_jwt(claims))
    end

    test "returns nil for malformed token (no dots)" do
      assert nil == OpenAI.decode_jwt_claims("not_a_jwt")
    end

    test "returns nil for token with only one dot" do
      assert nil == OpenAI.decode_jwt_claims("header.payload")
    end

    test "returns nil for token with invalid base64 payload" do
      assert nil == OpenAI.decode_jwt_claims("header.!!!invalid!!!.sig")
    end

    test "returns nil for token with non-JSON payload" do
      payload = Base.url_encode64("not json", padding: false)
      assert nil == OpenAI.decode_jwt_claims("header.#{payload}.sig")
    end
  end

  describe "extract_account_id/1" do
    test "extracts chatgpt_account_id from valid JWT" do
      token =
        build_test_jwt(%{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_abc123"}
        })

      assert "acct_abc123" == OpenAI.extract_account_id(token)
    end

    test "returns nil when auth claim exists but account_id is missing" do
      token =
        build_test_jwt(%{
          "https://api.openai.com/auth" => %{"some_other_field" => "value"}
        })

      assert nil == OpenAI.extract_account_id(token)
    end

    test "returns nil when auth claim path is absent" do
      assert nil == OpenAI.extract_account_id(build_test_jwt(%{"sub" => "user_123"}))
    end

    test "returns nil for nil token" do
      assert nil == OpenAI.extract_account_id(nil)
    end

    test "returns nil for malformed token" do
      assert nil == OpenAI.extract_account_id("garbage")
    end

    test "returns nil when account_id is not a string" do
      token =
        build_test_jwt(%{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => 12345}
        })

      assert nil == OpenAI.extract_account_id(token)
    end
  end

  defp build_test_jwt(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    "#{header}.#{payload}.fake_sig"
  end
end
