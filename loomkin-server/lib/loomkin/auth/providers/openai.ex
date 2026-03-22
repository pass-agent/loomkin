defmodule Loomkin.Auth.Providers.OpenAI do
  @moduledoc """
  OAuth provider adapter for OpenAI (ChatGPT Plus/Pro subscriptions via Codex backend).

  Implements OAuth 2.0 + PKCE against OpenAI's auth endpoints, ported from the
  `opencode-openai-codex-auth` TypeScript plugin. Uses a standard localhost redirect
  flow (not paste-back).

  ## How it works

  This uses the **ChatGPT consumer backend** (`chatgpt.com/backend-api`), NOT the
  Platform API (`api.openai.com/v1`). The auth flow uses the well-known Codex CLI
  client ID (public client, no secret needed).

  Key differences from the Platform API:
  - Different base URL: `https://chatgpt.com/backend-api`
  - URL rewriting: `/responses` → `/codex/responses`
  - Extra required headers: `chatgpt-account-id`, `OpenAI-Beta`, `originator`
  - `store: false` is mandatory in request body
  - Account ID extracted from JWT access token claims

  ## Configuration

  No configuration required — uses the shared Codex CLI client ID by default.
  Optional overrides in `.loomkin.toml`:

      [auth.openai]
      client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
      scopes = "openid profile email offline_access"
  """

  @behaviour Loomkin.Auth.Provider

  # ── Constants (from opencode-openai-codex-auth) ───────────────────

  # Default shared client ID (Codex CLI public client)
  @default_client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  # OAuth endpoints
  @default_authorize_url "https://auth.openai.com/oauth/authorize"
  @default_token_url "https://auth.openai.com/oauth/token"

  # Standard scopes
  @default_scopes ["openid", "profile", "email", "offline_access"]

  # JWT claim path for extracting chatgpt_account_id
  @jwt_claim_path "https://api.openai.com/auth"

  # ── Behaviour callbacks ─────────────────────────────────────────────

  @impl true
  def provider_name, do: :openai

  @impl true
  def display_name, do: "OpenAI"

  @impl true
  def authorize_url do
    get_config(:authorize_url, @default_authorize_url)
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
    %{state: state, code_verifier: code_verifier, redirect_uri: redirect_uri} = params

    query =
      [
        {"response_type", "code"},
        {"client_id", client_id()},
        {"redirect_uri", redirect_uri},
        {"scope", Enum.join(scopes(), " ")},
        {"code_challenge", Loomkin.Auth.Provider.code_challenge(code_verifier)},
        {"code_challenge_method", "S256"},
        {"state", state},
        # Codex-specific params
        {"id_token_add_organizations", "true"},
        {"codex_cli_simplified_flow", "true"},
        {"originator", "codex_cli_rs"}
      ]
      |> URI.encode_query()

    {:ok, "#{authorize_url()}?#{query}"}
  end

  @impl true
  def exchange_code(params) do
    %{code: code, code_verifier: code_verifier, redirect_uri: redirect_uri} = params

    # OpenAI uses standard form-encoded token exchange (NOT JSON like Anthropic)
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "client_id" => client_id(),
        "code" => code,
        "code_verifier" => code_verifier,
        "redirect_uri" => redirect_uri
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    case Req.post(token_url(), body: body, headers: headers) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        access_token = resp_body["access_token"]
        account_id = extract_account_id(access_token)

        token_data = %{
          access_token: access_token,
          refresh_token: resp_body["refresh_token"],
          expires_in: resp_body["expires_in"],
          account_id: account_id,
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
    # OpenAI uses form-encoded refresh, and refresh tokens are rotated
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token_value,
        "client_id" => client_id()
      })

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"}
    ]

    case Req.post(token_url(), body: body, headers: headers) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        access_token = resp_body["access_token"]
        account_id = extract_account_id(access_token)

        token_data = %{
          access_token: access_token,
          # OpenAI rotates refresh tokens — MUST use the new one
          refresh_token: resp_body["refresh_token"] || refresh_token_value,
          expires_in: resp_body["expires_in"],
          account_id: account_id,
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

  # ── JWT helpers ────────────────────────────────────────────────────

  @doc """
  Extract the `chatgpt_account_id` from a JWT access token.

  The access token is a JWT. The account ID is at:
  `payload["https://api.openai.com/auth"]["chatgpt_account_id"]`

  No signature verification — we only need the claims. Returns `nil`
  if the token is malformed or the claim is missing.

  ## Examples

      iex> decode_jwt_claims("header.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF8xMjMifX0.sig")
      %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_123"}}
  """
  @spec decode_jwt_claims(String.t() | nil) :: map() | nil
  def decode_jwt_claims(nil), do: nil

  def decode_jwt_claims(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        # JWT payload is base64url encoded (no padding)
        case Base.url_decode64(pad_base64(payload)) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, claims} -> claims
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Extract the `chatgpt_account_id` from a JWT access token.

  Returns the account ID string or `nil` if not found.
  """
  @spec extract_account_id(String.t() | nil) :: String.t() | nil
  def extract_account_id(token) do
    case decode_jwt_claims(token) do
      %{@jwt_claim_path => %{"chatgpt_account_id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  # ── Config helpers ──────────────────────────────────────────────────

  defp get_config(key, default) do
    case Loomkin.Config.get(:auth, :openai) do
      nil -> default
      config when is_map(config) -> Map.get(config, key, default)
      _ -> default
    end
  rescue
    # Config may not be available during startup/tests
    _ -> default
  end

  # ── Base64 padding helper ──────────────────────────────────────────

  defp pad_base64(str) do
    case rem(byte_size(str), 4) do
      0 -> str
      2 -> str <> "=="
      3 -> str <> "="
      _ -> str
    end
  end
end
