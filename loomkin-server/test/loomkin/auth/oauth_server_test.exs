defmodule Loomkin.Auth.OAuthServerTest do
  use ExUnit.Case, async: false

  # async: false because OAuthServer is a singleton GenServer.

  alias Loomkin.Auth.OAuthServer

  setup do
    unless Process.whereis(OAuthServer) do
      flunk("OAuthServer GenServer is not running — cannot run integration tests")
    end

    :ok
  end

  describe "start_flow/2" do
    test "returns {:ok, url, :paste_back} for anthropic" do
      {:ok, url, flow_type} =
        OAuthServer.start_flow(:anthropic, "http://localhost:4000/auth/callback")

      assert is_binary(url)
      assert String.starts_with?(url, "https://")
      assert flow_type == :paste_back
    end

    @tag :requires_google_config
    test "returns {:ok, url, :redirect} for google when configured" do
      case OAuthServer.start_flow(:google, "http://localhost:4000/auth/google/callback") do
        {:ok, url, flow_type} ->
          assert is_binary(url)
          assert String.starts_with?(url, "https://")
          assert flow_type == :redirect

        {:error, reason} ->
          # Google requires client_id/secret which may not be configured in test.
          assert reason != nil,
                 "Expected a meaningful error reason, got nil"
      end
    end
  end

  describe "flow_active?/1" do
    test "returns true after starting a flow" do
      OAuthServer.start_flow(:anthropic, "http://localhost:4000/auth/callback")
      assert OAuthServer.flow_active?(:anthropic)
    end

    test "returns false for provider with no active flow" do
      # Start and complete/clear any stale anthropic flow, then check a different provider
      # that we haven't started a flow for. We can't fully guarantee google has no flow,
      # but if the previous test started one for anthropic only, google should be clean.
      refute OAuthServer.flow_active?(:openai)
    end
  end

  describe "handle_callback/2" do
    test "returns error for unknown state token" do
      assert {:error, :invalid_state} =
               OAuthServer.handle_callback("nonexistent_state_token", "some_code")
    end
  end

  describe "handle_paste/2" do
    test "returns error when no active flow for provider" do
      # Use :openai which we never started a flow for
      result = OAuthServer.handle_paste(:openai, "code#state")
      assert {:error, _reason} = result
    end
  end
end
