defmodule Loomkin.Auth.Providers.Google do
  @moduledoc """
  OAuth provider adapter for Google (Gemini / Vertex AI).

  Uses the Assent library's built-in Google strategy (OIDC) for the OAuth flow,
  while conforming to the `Loomkin.Auth.Provider` behaviour so it integrates
  seamlessly with OAuthServer and TokenStore.

  ## How it works

  Assent manages OIDC discovery, PKCE, state validation, and token exchange
  internally. This module bridges between our `Provider` behaviour (used by
  OAuthServer) and Assent's API:

  - `build_authorize_url/1` calls Assent, passes OAuthServer's state token
    through, and stashes Assent's `session_params` in an ETS table keyed by
    state for retrieval during the callback.
  - `exchange_code/1` retrieves the stashed session_params and delegates to
    Assent's callback to exchange the code for tokens.
  - `refresh_token/1` calls `Assent.Strategy.OAuth2.refresh_access_token/3`
    directly with the Google token endpoint.

  ## Configuration

  Requires `client_id` and `client_secret` in `.loomkin.toml`:

      [auth.google]
      client_id = "your-google-client-id.apps.googleusercontent.com"
      client_secret = "GOCSPX-..."

  ## Scopes

  Uses `https://www.googleapis.com/auth/cloud-platform` by default, which
  covers both the Generative Language API and Vertex AI. The OIDC layer
  automatically prepends `openid`.
  """

  @behaviour Loomkin.Auth.Provider

  # ── Constants ──────────────────────────────────────────────────────

  @default_scope "https://www.googleapis.com/auth/cloud-platform"

  # Google's token endpoint — needed for refresh (OIDC discovery only runs
  # during the authorize/callback flow, not during refresh)
  @google_token_url "https://oauth2.googleapis.com/token"

  # ETS table for stashing Assent session_params between authorize and callback
  @session_table :loomkin_google_oauth_sessions

  # ── Behaviour callbacks ─────────────────────────────────────────────

  @impl true
  def provider_name, do: :google

  @impl true
  def display_name, do: "Google"

  @impl true
  def authorize_url, do: "https://accounts.google.com/o/oauth2/v2/auth"

  @impl true
  def token_url, do: @google_token_url

  @impl true
  def scopes do
    case get_config(:scopes, [@default_scope]) do
      scopes when is_list(scopes) -> scopes
      scope when is_binary(scope) -> [scope]
    end
  end

  @impl true
  def client_id, do: get_config(:client_id, nil)

  @impl true
  def build_authorize_url(params) do
    %{state: state_token, redirect_uri: redirect_uri} = params

    config = assent_config(redirect_uri, state_token)

    case Assent.Strategy.Google.authorize_url(config) do
      {:ok, %{url: url, session_params: session_params}} ->
        # Stash session_params keyed by the state token so we can retrieve
        # them in exchange_code when the callback arrives
        :ets.insert(@session_table, {state_token, session_params, System.monotonic_time(:second)})

        {:ok, url}

      {:error, error} ->
        {:error, {:authorize_url_failed, error}}
    end
  end

  @impl true
  def exchange_code(params) do
    %{code: code, redirect_uri: redirect_uri, state: state_token} = params

    # Retrieve the stashed session_params from the authorize phase
    case pop_session_params(state_token) do
      nil ->
        {:error, :session_params_not_found}

      session_params ->
        config =
          assent_config(redirect_uri, state_token)
          |> Keyword.put(:session_params, session_params)

        # Assent expects the callback params as a string-keyed map
        callback_params = %{"code" => code, "state" => state_token}

        case Assent.Strategy.Google.callback(config, callback_params) do
          {:ok, %{token: token, user: user}} ->
            token_data = %{
              access_token: token["access_token"],
              refresh_token: token["refresh_token"],
              expires_in: token["expires_in"],
              account_id: user["sub"],
              scopes: token["scope"]
            }

            {:ok, token_data}

          {:error, error} ->
            {:error, {:token_exchange_failed, error}}
        end
    end
  end

  @impl true
  def refresh_token(refresh_token_value) do
    config = [
      client_id: client_id(),
      client_secret: client_secret(),
      base_url: "https://accounts.google.com/",
      token_url: @google_token_url,
      auth_method: :client_secret_post
    ]

    token_map = %{"refresh_token" => refresh_token_value}

    case Assent.Strategy.OAuth2.refresh_access_token(config, token_map) do
      {:ok, new_token} ->
        token_data = %{
          access_token: new_token["access_token"],
          # Google typically doesn't return a new refresh token on refresh
          refresh_token: new_token["refresh_token"] || refresh_token_value,
          expires_in: new_token["expires_in"],
          scopes: new_token["scope"]
        }

        {:ok, token_data}

      {:error, error} ->
        {:error, {:refresh_failed, error}}
    end
  end

  @impl true
  def supports_refresh?, do: true

  # ── Public helpers ─────────────────────────────────────────────────

  @doc "Returns the configured client_secret, or nil."
  @impl true
  @spec client_secret() :: String.t() | nil
  def client_secret, do: get_config(:client_secret, nil)

  # ── Private helpers ────────────────────────────────────────────────

  defp assent_config(redirect_uri, state_token) do
    [
      client_id: client_id(),
      client_secret: client_secret(),
      redirect_uri: redirect_uri,
      # Pass OAuthServer's state token so Assent uses it (not a random one)
      state: state_token,
      # Enable PKCE — Assent will generate its own code_verifier internally
      code_verifier: true,
      # Generate a real nonce string — passing `true` causes Assent 0.3.1 to store
      # the boolean rather than a random value, breaking constant_time_compare/2
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      authorization_params: [
        access_type: "offline",
        prompt: "consent",
        scope: Enum.join(scopes(), " ")
      ]
    ]
  end

  defp get_config(key, default) do
    case Loomkin.Config.get(:auth, :google) do
      nil -> default
      config when is_map(config) -> Map.get(config, key, default)
      _ -> default
    end
  rescue
    # Config may not be available during startup/tests
    _ -> default
  end

  # ── Session params ETS management ──────────────────────────────────
  # NOTE: The ETS table is created and owned by OAuthServer in its init/1.

  defp pop_session_params(state_token) do
    case :ets.lookup(@session_table, state_token) do
      [{^state_token, session_params, _inserted_at}] ->
        :ets.delete(@session_table, state_token)
        session_params

      [] ->
        nil
    end
  rescue
    ArgumentError ->
      # Table doesn't exist
      nil
  end
end
