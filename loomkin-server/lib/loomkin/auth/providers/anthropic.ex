defmodule Loomkin.Auth.Providers.Anthropic do
  @moduledoc """
  OAuth provider adapter for Anthropic (Claude Pro/Teams subscriptions).

  Implements OAuth 2.0 + PKCE against Anthropic's OAuth endpoints, ported
  from the `anthropic-auth` Rust crate. Supports two modes:

  - **Max** — Uses `claude.ai` domain for subscription-based inference
  - **Console** — Uses `console.anthropic.com` for API key creation

  The redirect URI points to Anthropic's own domain (not localhost),
  so the user must paste the `code#state` string back into Loomkin.
  This is the "paste-back" flow.

  ## Configuration

  Endpoints and client_id can be overridden in `.loomkin.toml`:

      [auth.anthropic]
      client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
      mode = "max"   # or "console"
      scopes = ["org:create_api_key", "user:profile", "user:inference"]
  """

  @behaviour Loomkin.Auth.Provider

  # ── Constants (from anthropic-auth Rust crate) ─────────────────────

  # Default shared client ID (Claude CLI public client)
  @default_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  # Token exchange & refresh endpoint (note: /v1/ prefix)
  @default_token_url "https://console.anthropic.com/v1/oauth/token"

  # Full scopes matching the Rust crate
  @default_scopes ["org:create_api_key", "user:profile", "user:inference"]

  # Redirect URI — Anthropic's own domain, NOT localhost.
  # This is why we need the paste-back flow.
  @redirect_uri "https://console.anthropic.com/oauth/code/callback"

  # API key creation endpoint (for Console mode)
  @api_key_url "https://api.anthropic.com/api/oauth/claude_cli/create_api_key"

  # ── OAuth mode ─────────────────────────────────────────────────────

  @type oauth_mode :: :max | :console

  @doc """
  Returns the authorize URL base domain for the given mode.

  - `:max` → `https://claude.ai/oauth/authorize`
  - `:console` → `https://console.anthropic.com/oauth/authorize`
  """
  @spec authorize_url_for_mode(oauth_mode()) :: String.t()
  def authorize_url_for_mode(:max), do: "https://claude.ai/oauth/authorize"
  def authorize_url_for_mode(:console), do: "https://console.anthropic.com/oauth/authorize"

  @doc "Returns the currently configured mode (`:max` or `:console`)."
  @spec mode() :: oauth_mode()
  def mode do
    case get_config(:mode, "max") do
      "console" -> :console
      "max" -> :max
      :console -> :console
      :max -> :max
      _ -> :max
    end
  end

  # ── Behaviour callbacks ─────────────────────────────────────────────

  @impl true
  def provider_name, do: :anthropic

  @impl true
  def display_name, do: "Anthropic"

  @impl true
  def authorize_url do
    authorize_url_for_mode(mode())
  end

  @impl true
  def token_url do
    get_config(:token_url, @default_token_url)
  end

  @impl true
  def scopes do
    get_config(:scopes, @default_scopes)
  end

  @impl true
  def client_id do
    get_config(:client_id, @default_client_id)
  end

  @impl true
  def build_authorize_url(params) do
    %{state: state, code_verifier: code_verifier} = params
    # mode can be overridden per-flow via params, or falls back to config
    current_mode = Map.get(params, :mode, mode())

    query =
      [
        {"code", "true"},
        {"client_id", client_id()},
        {"response_type", "code"},
        {"redirect_uri", @redirect_uri},
        {"scope", Enum.join(scopes(), " ")},
        {"code_challenge", Loomkin.Auth.Provider.code_challenge(code_verifier)},
        {"code_challenge_method", "S256"},
        {"state", state}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> URI.encode_query()

    {:ok, "#{authorize_url_for_mode(current_mode)}?#{query}"}
  end

  @impl true
  def exchange_code(params) do
    %{code: code, code_verifier: code_verifier} = params
    # state is required in the Anthropic token exchange body
    state = Map.get(params, :state, "")

    body =
      %{
        "grant_type" => "authorization_code",
        "code" => code,
        "state" => state,
        "client_id" => client_id(),
        "redirect_uri" => @redirect_uri,
        "code_verifier" => code_verifier
      }

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case Req.post(token_url(), json: body, headers: headers) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        token_data = %{
          access_token: resp_body["access_token"],
          refresh_token: resp_body["refresh_token"],
          expires_in: resp_body["expires_in"],
          account_id: resp_body["account_id"] || resp_body["organization_id"],
          scopes: resp_body["scope"]
        }

        {:ok, token_data}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:token_exchange_failed, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @impl true
  def refresh_token(refresh_token_value) do
    body =
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token_value,
        "client_id" => client_id()
      }

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case Req.post(token_url(), json: body, headers: headers) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        token_data = %{
          access_token: resp_body["access_token"],
          refresh_token: resp_body["refresh_token"] || refresh_token_value,
          expires_in: resp_body["expires_in"],
          account_id: resp_body["account_id"] || resp_body["organization_id"],
          scopes: resp_body["scope"]
        }

        {:ok, token_data}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:refresh_failed, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @impl true
  def supports_refresh?, do: true

  # ── Paste-back helpers ─────────────────────────────────────────────

  @doc """
  The fixed redirect URI for Anthropic OAuth (their domain, not ours).
  """
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri

  @doc """
  Parse the paste-back string from the user.

  Anthropic returns a combined `code#state` string. This splits it and
  validates the state against the expected value.

  Returns `{:ok, code, state}` or `{:error, reason}`.

  ## Examples

      iex> parse_code_and_state("abc123#xyz789", "xyz789")
      {:ok, "abc123", "xyz789"}

      iex> parse_code_and_state("abc123#wrong", "xyz789")
      {:error, :state_mismatch}

      iex> parse_code_and_state("just_a_code", "xyz789")
      {:ok, "just_a_code", "xyz789"}
  """
  @spec parse_code_and_state(String.t(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :state_mismatch}
  def parse_code_and_state(code_with_state, expected_state) do
    case String.split(code_with_state, "#", parts: 2) do
      [code, returned_state] ->
        if returned_state == expected_state do
          {:ok, code, returned_state}
        else
          {:error, :state_mismatch}
        end

      [code_only] ->
        # No "#" found — assume just the code was provided
        {:ok, code_only, expected_state}
    end
  end

  @doc """
  Create an API key using a Console-mode OAuth access token.

  Only available when using Console mode. Creates a new API key
  via Anthropic's CLI key creation endpoint.

  Returns `{:ok, api_key_string}` or `{:error, reason}`.
  """
  @spec create_api_key(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_api_key(access_token) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case Req.post(@api_key_url, json: %{}, headers: headers) do
      {:ok, %Req.Response{status: 200, body: %{"raw_key" => key}}} when key != "" ->
        {:ok, key}

      {:ok, %Req.Response{status: 200, body: _resp_body}} ->
        {:error, :empty_api_key}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:api_key_failed, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # ── Config helpers ──────────────────────────────────────────────────

  defp get_config(key, default) do
    case Loomkin.Config.get(:auth, :anthropic) do
      nil -> default
      config when is_map(config) -> Map.get(config, key, default)
      _ -> default
    end
  rescue
    # Config may not be available during startup/tests
    _ -> default
  end
end
