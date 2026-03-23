defmodule Loomkin.Providers.OAuthAdaptersTest do
  @moduledoc """
  Integration tests for OAuth ReqLLM adapters (AnthropicOAuth, OpenAIOAuth, GoogleOAuth).

  Tests token retrieval, model name resolution, build_authorize_url return types,
  and error handling without making HTTP requests.
  """

  use Loomkin.DataCase, async: false

  alias Loomkin.Auth.TokenStore
  alias Loomkin.Providers.{AnthropicOAuth, OpenAIOAuth, GoogleOAuth}

  setup do
    # Ensure no stale tokens leak between tests
    for provider <- [:anthropic, :openai, :google] do
      TokenStore.revoke_tokens(provider)
    end

    on_exit(fn ->
      for provider <- [:anthropic, :openai, :google] do
        TokenStore.revoke_tokens(provider)
      end
    end)

    :ok
  end

  # ── Token retrieval — no token → clean error ───────────────────────

  describe "prepare_request returns {:error, :no_oauth_token} when no token stored" do
    test "AnthropicOAuth" do
      assert {:error, :no_oauth_token} =
               AnthropicOAuth.prepare_request(
                 :chat,
                 "anthropic_oauth:claude-sonnet-4-6",
                 "hi",
                 []
               )
    end

    test "OpenAIOAuth" do
      assert {:error, :no_oauth_token} =
               OpenAIOAuth.prepare_request(:chat, "openai_oauth:gpt-4o", "hi", [])
    end

    test "GoogleOAuth" do
      assert {:error, :no_oauth_token} =
               GoogleOAuth.prepare_request(:chat, "google_oauth:gemini-2.0-flash", "hi", [])
    end
  end

  # ── Token retrieval — with token, fetch succeeds ───────────────────

  describe "prepare_request gets past token fetch when token is stored" do
    test "AnthropicOAuth does not return :no_oauth_token" do
      store_test_token(:anthropic, "test-anthropic-token")

      result =
        try do
          AnthropicOAuth.prepare_request(:chat, "anthropic_oauth:claude-sonnet-4-6", "hello", [])
        rescue
          # May raise from deep Req option registration — that's fine,
          # it means we got past the token fetch
          ArgumentError -> :got_past_token_fetch
        end

      # May fail downstream (model resolution, Req options, etc.) but must NOT
      # fail with :no_oauth_token — that proves the token was fetched
      refute match?({:error, :no_oauth_token}, result)
    end

    test "OpenAIOAuth does not return :no_oauth_token" do
      store_test_token(:openai, "test-openai-token")

      result =
        try do
          OpenAIOAuth.prepare_request(:chat, "openai_oauth:gpt-4o", "hello", [])
        rescue
          # May raise from deep Req option registration — that's fine,
          # it means we got past the token fetch
          ArgumentError -> :got_past_token_fetch
        end

      refute match?({:error, :no_oauth_token}, result)
    end

    test "GoogleOAuth does not return :no_oauth_token" do
      store_test_token(:google, "test-google-token")

      result =
        try do
          GoogleOAuth.prepare_request(:chat, "google_oauth:gemini-2.0-flash", "hello", [])
        rescue
          ArgumentError -> :got_past_token_fetch
        end

      refute match?({:error, :no_oauth_token}, result)
    end
  end

  # ── build_authorize_url returns {:ok, url} ─────────────────────────

  describe "build_authorize_url returns {:ok, url} tuple" do
    test "Anthropic" do
      params = %{
        state: "test-state",
        code_verifier: "test-verifier-12345678901234567890123456789012"
      }

      assert {:ok, url} = Loomkin.Auth.Providers.Anthropic.build_authorize_url(params)
      assert String.starts_with?(url, "https://claude.ai/oauth/authorize?")
      assert String.contains?(url, "state=test-state")
    end

    test "OpenAI" do
      params = %{
        state: "test-state",
        code_verifier: "test-verifier-12345678901234567890123456789012",
        redirect_uri: "http://localhost:4000/auth/openai/callback"
      }

      assert {:ok, url} = Loomkin.Auth.Providers.OpenAI.build_authorize_url(params)
      assert String.starts_with?(url, "https://auth.openai.com/oauth/authorize?")
      assert String.contains?(url, "state=test-state")
    end
  end

  # ── Unsupported operations ─────────────────────────────────────────

  describe "unsupported operations return errors" do
    test "AnthropicOAuth rejects :embedding" do
      assert {:error, _} =
               AnthropicOAuth.prepare_request(:embedding, "anthropic_oauth:model", "hi", [])
    end

    test "OpenAIOAuth rejects :embedding" do
      assert {:error, _} =
               OpenAIOAuth.prepare_request(:embedding, "openai_oauth:model", "hi", [])
    end

    test "GoogleOAuth rejects :transcription" do
      assert {:error, _} =
               GoogleOAuth.prepare_request(:transcription, "google_oauth:model", "hi", [])
    end
  end

  describe "OpenAIOAuth codex request shaping" do
    test "moves system input text into instructions" do
      body = %{
        "input" => [
          %{
            "role" => "system",
            "content" => [%{"type" => "input_text", "text" => "be concise"}]
          },
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "hello"}]
          }
        ]
      }

      patched = OpenAIOAuth.inject_instructions_from_input(body)

      assert patched["instructions"] == "be concise"
      assert Enum.all?(patched["input"], &(&1["role"] != "system"))
    end

    test "drops max_output_tokens for codex backend" do
      body = %{
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "hello"}]
          }
        ],
        "max_output_tokens" => 1024
      }

      patched = OpenAIOAuth.inject_instructions_from_input(body)

      refute Map.has_key?(patched, "max_output_tokens")
    end

    test "decodes responses api stream deltas" do
      {:ok, model} = ReqLLM.model("openai:gpt-5.3-codex")

      event = %{
        data: %{
          "event" => "response.output_text.delta",
          "delta" => "hello"
        }
      }

      chunks = OpenAIOAuth.decode_stream_event(event, model)

      assert Enum.any?(chunks, fn chunk ->
               chunk.type == :content and chunk.text == "hello"
             end)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp store_test_token(provider, access_token) do
    token_data = %{
      access_token: access_token,
      refresh_token: "test-refresh-token",
      expires_in: 3600,
      account_id: "test-account-#{provider}",
      scopes: "test"
    }

    :ok = TokenStore.store_tokens(provider, token_data)
  end
end
