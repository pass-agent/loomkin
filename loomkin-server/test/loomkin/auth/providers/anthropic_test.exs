defmodule Loomkin.Auth.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias Loomkin.Auth.Providers.Anthropic

  test "provider_name/0 returns :anthropic" do
    assert :anthropic == Anthropic.provider_name()
  end

  test "display_name/0 returns human-readable name" do
    assert "Anthropic" == Anthropic.display_name()
  end

  test "authorize_url/0 returns a valid HTTPS URL" do
    assert String.starts_with?(Anthropic.authorize_url(), "https://")
  end

  test "token_url/0 returns the Anthropic token endpoint with /v1/ prefix" do
    assert "https://console.anthropic.com/v1/oauth/token" == Anthropic.token_url()
  end

  test "supports_refresh?/0 returns true" do
    assert Anthropic.supports_refresh?()
  end

  test "redirect_uri/0 returns Anthropic's callback URL (not localhost)" do
    uri = Anthropic.redirect_uri()
    assert uri == "https://console.anthropic.com/oauth/code/callback"
    refute String.contains?(uri, "localhost")
  end

  describe "scopes/0" do
    test "includes required scopes" do
      scopes = Anthropic.scopes()
      assert "org:create_api_key" in scopes
      assert "user:profile" in scopes
      assert "user:inference" in scopes
    end
  end

  describe "client_id/0" do
    test "returns a UUID-formatted string" do
      client_id = Anthropic.client_id()
      assert is_binary(client_id)
      assert String.length(client_id) == 36
      assert String.contains?(client_id, "-")
    end
  end

  describe "mode/0" do
    test "returns :max or :console" do
      assert Anthropic.mode() in [:max, :console]
    end
  end

  describe "authorize_url_for_mode/1" do
    test ":max returns claude.ai domain" do
      assert "https://claude.ai/oauth/authorize" == Anthropic.authorize_url_for_mode(:max)
    end

    test ":console returns console.anthropic.com domain" do
      assert "https://console.anthropic.com/oauth/authorize" ==
               Anthropic.authorize_url_for_mode(:console)
    end
  end

  describe "build_authorize_url/1" do
    test "includes all required query parameters" do
      {:ok, url} =
        Anthropic.build_authorize_url(%{
          state: "test_state_123",
          code_verifier: "test_verifier_abcdefghijklmnop1234567890abcdef"
        })

      params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert params["code"] == "true"
      assert params["client_id"] != nil
      assert params["response_type"] == "code"
      assert params["redirect_uri"] == "https://console.anthropic.com/oauth/code/callback"
      assert params["code_challenge_method"] == "S256"
      assert params["state"] == "test_state_123"
      assert params["scope"] != nil
      assert params["code_challenge"] != nil
    end

    test "uses max mode URL by default" do
      {:ok, url} =
        Anthropic.build_authorize_url(%{
          state: "s",
          code_verifier: "v_abcdefghijklmnop1234567890abcdef1234567"
        })

      expected_host = if Anthropic.mode() == :max, do: "claude.ai", else: "console.anthropic.com"
      assert URI.parse(url).host == expected_host
    end

    test "respects mode override in params" do
      {:ok, url} =
        Anthropic.build_authorize_url(%{
          state: "s",
          code_verifier: "v_abcdefghijklmnop1234567890abcdef1234567",
          mode: :console
        })

      assert URI.parse(url).host == "console.anthropic.com"
    end

    test "code_challenge is derived from code_verifier (S256)" do
      verifier = "test_verifier_abcdefghijklmnop1234567890abcdef"

      {:ok, url} = Anthropic.build_authorize_url(%{state: "s", code_verifier: verifier})

      expected_challenge =
        :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

      params = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert params["code_challenge"] == expected_challenge
    end
  end

  describe "parse_code_and_state/2" do
    test "parses code#state format correctly" do
      assert {:ok, "auth_code_123", "state_789"} =
               Anthropic.parse_code_and_state("auth_code_123#state_789", "state_789")
    end

    test "returns state_mismatch when state doesn't match" do
      assert {:error, :state_mismatch} =
               Anthropic.parse_code_and_state("auth_code_123#wrong_state", "expected_state")
    end

    test "handles code without # separator (code only)" do
      assert {:ok, "just_a_code", "expected_state"} =
               Anthropic.parse_code_and_state("just_a_code", "expected_state")
    end

    test "handles empty code before #" do
      assert {:ok, "", "state_123"} =
               Anthropic.parse_code_and_state("#state_123", "state_123")
    end

    test "only splits on first # (code can contain #)" do
      assert {:ok, "code", "state#extra"} =
               Anthropic.parse_code_and_state("code#state#extra", "state#extra")
    end

    test "handles long code and state values" do
      long_code = String.duplicate("a", 200)
      long_state = String.duplicate("b", 100)

      assert {:ok, ^long_code, ^long_state} =
               Anthropic.parse_code_and_state("#{long_code}##{long_state}", long_state)
    end
  end
end
