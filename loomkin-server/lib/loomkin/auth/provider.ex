defmodule Loomkin.Auth.Provider do
  @moduledoc """
  Behaviour for OAuth provider adapters.

  Each provider (Anthropic, OpenAI, etc.) implements this behaviour to
  define its OAuth endpoints, scopes, and token exchange/refresh logic.

  ## Registry

  Provider modules register themselves at compile time. Use `module_for/1`
  to look up the module for a given provider atom (e.g., `:anthropic`).
  """

  @doc "Unique provider identifier atom (e.g., `:anthropic`)"
  @callback provider_name() :: atom()

  @doc "Human-readable display name"
  @callback display_name() :: String.t()

  @doc "OAuth authorization URL (where the browser is sent)"
  @callback authorize_url() :: String.t()

  @doc "OAuth token exchange URL"
  @callback token_url() :: String.t()

  @doc "Default scopes to request"
  @callback scopes() :: [String.t()]

  @doc "OAuth client ID (may come from config)"
  @callback client_id() :: String.t() | nil

  @doc """
  OAuth client secret (may come from config).

  Optional — public clients using PKCE (e.g., Anthropic) don't need a secret.
  Providers that require a secret (e.g., Google with `client_secret_post`)
  must implement this callback.
  """
  @callback client_secret() :: String.t() | nil

  @optional_callbacks [client_secret: 0]

  @doc """
  Build the full authorization URL with all required query parameters.

  Receives a map with:
  - `:state` — CSRF state string
  - `:code_verifier` — PKCE code verifier (raw)
  - `:redirect_uri` — callback URL

  Returns the full URL to redirect the browser to.
  """
  @callback build_authorize_url(params :: map()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Exchange an authorization code for tokens.

  Receives a map with:
  - `:code` — the authorization code from the callback
  - `:code_verifier` — the PKCE code verifier
  - `:redirect_uri` — the callback URL used in the authorize request

  Returns `{:ok, token_data}` where `token_data` is a map with at least
  `:access_token`, and optionally `:refresh_token`, `:expires_in`,
  `:account_id`, `:scopes`.
  """
  @callback exchange_code(params :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Refresh an expired access token using a refresh token.

  Returns `{:ok, token_data}` with the new tokens, or `{:error, reason}`.
  """
  @callback refresh_token(refresh_token :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Whether this provider supports token refresh.
  """
  @callback supports_refresh?() :: boolean()

  # ── Registry (delegates to ProviderRegistry) ────────────────────────

  alias Loomkin.Auth.ProviderRegistry

  @doc """
  Returns the provider module for the given provider atom.

  Raises `ArgumentError` if the provider is not registered.
  """
  @spec module_for(atom()) :: module()
  def module_for(provider) when is_atom(provider) do
    ProviderRegistry.auth_module_for!(provider)
  end

  @doc """
  Returns all registered provider atoms.
  """
  @spec registered_providers() :: [atom()]
  def registered_providers, do: ProviderRegistry.provider_ids()

  @doc """
  Returns a map of provider atom to display name for all registered providers.
  """
  @spec provider_names() :: %{atom() => String.t()}
  def provider_names do
    ProviderRegistry.all()
    |> Map.new(fn entry -> {entry.id, entry.display_name} end)
  end

  # ── Shared helpers ──────────────────────────────────────────────────

  @doc """
  Generates a PKCE code verifier (43-128 chars, URL-safe base64).
  """
  @spec generate_code_verifier() :: String.t()
  def generate_code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Derives the PKCE code challenge from a code verifier (S256 method).
  """
  @spec code_challenge(String.t()) :: String.t()
  def code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Generates a random state string for CSRF protection (32 bytes, URL-safe base64).
  """
  @spec generate_state() :: String.t()
  def generate_state do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end
end
