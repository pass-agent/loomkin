defmodule LoomkinWeb.AuthController do
  @moduledoc """
  Handles OAuth authorization flows for provider subscriptions.

  ## Routes

  - `GET /auth/:provider` — initiates the OAuth flow (redirects or returns JSON for paste-back)
  - `GET /auth/:provider/callback` — handles the provider's redirect back with auth code
  - `POST /auth/:provider/paste` — handles paste-back submission (for providers like Anthropic)
  - `DELETE /auth/:provider` — disconnects (revokes) the provider's OAuth tokens
  - `GET /auth/:provider/status` — returns JSON status for the provider
  """

  use LoomkinWeb, :controller

  alias Loomkin.Auth.OAuthServer
  alias Loomkin.Auth.ProviderRegistry
  alias Loomkin.Auth.TokenStore

  @doc """
  Initiate OAuth flow.

  For `:redirect` providers, redirects the browser to the provider's auth page.
  For `:paste_back` providers, returns JSON with the authorize URL and flow type
  so the LiveView UI can open the URL in a new window and show a paste-back modal.
  """
  def authorize(conn, %{"provider" => provider}) do
    with :ok <- validate_provider(provider) do
      provider_atom = String.to_existing_atom(provider)
      redirect_uri = callback_url(conn, provider)

      case OAuthServer.start_flow(provider_atom, redirect_uri) do
        {:ok, authorize_url, :paste_back} ->
          # Paste-back flow: return JSON so the UI can open a new window
          # and show the paste-back modal simultaneously
          json(conn, %{
            flow_type: "paste_back",
            authorize_url: authorize_url,
            provider: provider
          })

        {:ok, authorize_url, :redirect} ->
          # Standard redirect flow
          redirect(conn, external: authorize_url)

        {:error, _reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Failed to start OAuth flow. Please try again."})
      end
    else
      {:error, :unknown_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unknown provider: #{provider}"})
    end
  end

  @doc """
  Handle OAuth callback from the provider (standard redirect flow).
  Validates state, exchanges code for tokens, then redirects back to the app.
  """
  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    with :ok <- validate_provider(provider) do
      case OAuthServer.handle_callback(state, code) do
        :ok ->
          conn
          |> put_flash(:info, "Connected to #{String.capitalize(provider)} successfully!")
          |> redirect(to: "/")

        {:error, :invalid_state} ->
          conn
          |> put_flash(:error, "OAuth flow expired or invalid. Please try again.")
          |> redirect(to: "/")

        {:error, _reason} ->
          conn
          |> put_flash(
            :error,
            "Failed to connect to #{String.capitalize(provider)}. Please try again."
          )
          |> redirect(to: "/")
      end
    else
      {:error, :unknown_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unknown provider: #{provider}"})
    end
  end

  def callback(conn, %{"provider" => _provider, "error" => _error} = params) do
    description = params["error_description"] || "unknown error"

    conn
    |> put_flash(:error, "Authorization denied: #{description}")
    |> redirect(to: "/")
  end

  def callback(conn, %{"provider" => _provider}) do
    conn
    |> put_flash(:error, "Invalid OAuth callback (missing code or state).")
    |> redirect(to: "/")
  end

  @doc """
  Handle paste-back submission for providers that redirect to their own domain
  (e.g., Anthropic). The user pastes the `code#state` string from the provider.

  Returns JSON with `{status: "ok"}` or `{error: "reason"}`.
  """
  def paste(conn, %{"provider" => provider, "code_with_state" => code_with_state}) do
    with :ok <- validate_provider(provider) do
      provider_atom = String.to_existing_atom(provider)

      case OAuthServer.handle_paste(provider_atom, code_with_state) do
        :ok ->
          json(conn, %{
            status: "ok",
            message: "Connected to #{String.capitalize(provider)} successfully!"
          })

        {:error, :no_active_flow} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: "No active OAuth flow for #{provider}. Please start a new flow."})

        {:error, :state_mismatch} ->
          conn
          |> put_status(:bad_request)
          |> json(%{error: "State validation failed. The pasted code may be invalid or expired."})

        {:error, _reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{
            error: "Failed to connect to #{String.capitalize(provider)}. Please try again."
          })
      end
    else
      {:error, :unknown_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unknown provider: #{provider}"})
    end
  end

  def paste(conn, %{"provider" => _provider}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing code_with_state parameter."})
  end

  @doc """
  Disconnect a provider (revoke tokens).
  """
  def disconnect(conn, %{"provider" => provider}) do
    with :ok <- validate_provider(provider) do
      provider_atom = String.to_existing_atom(provider)
      :ok = TokenStore.revoke_tokens(provider_atom)

      conn
      |> put_flash(:info, "Disconnected from #{String.capitalize(provider)}.")
      |> redirect(to: "/")
    else
      {:error, :unknown_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unknown provider: #{provider}"})
    end
  end

  @doc """
  Returns JSON status for a provider's OAuth connection.
  Used by LiveView for polling status during auth flows.
  """
  def status(conn, %{"provider" => provider}) do
    with :ok <- validate_provider(provider) do
      provider_atom = String.to_existing_atom(provider)

      status_info =
        case TokenStore.get_status(provider_atom) do
          nil -> %{connected: false, flow_active: OAuthServer.flow_active?(provider_atom)}
          info -> info
        end

      json(conn, status_info)
    else
      {:error, :unknown_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unknown provider: #{provider}"})
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp validate_provider(provider) do
    if provider in ProviderRegistry.provider_id_strings() do
      :ok
    else
      {:error, :unknown_provider}
    end
  end

  defp callback_url(conn, provider) do
    base =
      case Loomkin.Config.get(:auth, :callback_base_url) do
        url when is_binary(url) ->
          String.trim_trailing(url, "/")

        _ ->
          scheme = if conn.scheme == :https, do: "https", else: "http"
          port_str = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
          "#{scheme}://#{conn.host}#{port_str}"
      end

    "#{base}/auth/#{provider}/callback"
  end
end
