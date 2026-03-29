defmodule LoomkinWeb.Api.OAuthController do
  @moduledoc """
  API endpoints for OAuth provider flows, authenticated via bearer token.

  These mirror the browser-based routes in `LoomkinWeb.AuthController` but
  accept bearer token auth so CLI and mobile clients can initiate and poll
  OAuth flows without a browser session.
  """

  use LoomkinWeb, :controller

  alias Loomkin.Auth.OAuthServer
  alias Loomkin.Auth.ProviderRegistry
  alias Loomkin.Auth.TokenStore

  @doc "Start an OAuth flow for the given provider. Returns the authorize URL and flow type."
  def start(conn, %{"provider" => provider}) do
    with :ok <- validate_provider(provider) do
      provider_atom = String.to_existing_atom(provider)
      redirect_uri = callback_url(conn, provider)

      case OAuthServer.start_flow(provider_atom, redirect_uri) do
        {:ok, url, flow_type} ->
          json(conn, %{url: url, flow_type: flow_type})

        {:error, {:authorize_url_failed, :missing_credentials}} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{
            error:
              "#{provider} OAuth is not configured. Add client_id and client_secret to .loomkin.toml under [auth.#{provider}]."
          })

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

  @doc "Return current OAuth connection status for the given provider."
  def status(conn, %{"provider" => provider}) do
    with :ok <- validate_provider(provider) do
      provider_atom = String.to_existing_atom(provider)

      flow_active = OAuthServer.flow_active?(provider_atom)

      status_info =
        case TokenStore.get_status(provider_atom) do
          nil -> %{connected: false, flow_active: flow_active}
          info -> Map.put(info, :flow_active, flow_active)
        end

      json(conn, status_info)
    else
      {:error, :unknown_provider} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unknown provider: #{provider}"})
    end
  end

  @doc "Handle paste-back code submission for providers like Anthropic."
  def paste(conn, %{"provider" => provider, "code_state" => code_state}) do
    with :ok <- validate_provider(provider) do
      provider_atom = String.to_existing_atom(provider)

      case OAuthServer.handle_paste(provider_atom, code_state) do
        :ok ->
          json(conn, %{connected: true})

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
          |> json(%{error: "Failed to connect #{provider}. Please try again."})
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
    |> json(%{error: "Missing code_state parameter."})
  end

  @doc "Revoke OAuth tokens for the given provider."
  def disconnect(conn, %{"provider" => provider}) do
    with :ok <- validate_provider(provider) do
      provider_atom = String.to_existing_atom(provider)
      :ok = TokenStore.revoke_tokens(provider_atom)
      json(conn, %{disconnected: true})
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
