defmodule LoomkinWeb.Api.DeviceAuthController do
  use LoomkinWeb, :controller

  alias Loomkin.DeviceAuth

  action_fallback LoomkinWeb.Api.FallbackController

  @doc """
  POST /api/v1/device/code
  Initiates a device authorization request.
  """
  def create_code(conn, %{"client_id" => "loomkin-cli"} = params) do
    scope = params["scope"] || "vault:read vault:write"

    case DeviceAuth.create_device_code("loomkin-cli", scope) do
      {:ok, result} ->
        conn
        |> put_status(:ok)
        |> json(result)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def create_code(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_client", message: "client_id must be 'loomkin-cli'"})
  end

  @doc """
  POST /api/v1/device/token
  Polls for the status of a device code.
  """
  def poll_token(conn, %{
        "device_code" => device_code,
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
      }) do
    case DeviceAuth.poll_device_code(device_code) do
      {:ok, :pending} ->
        conn
        |> put_status(428)
        |> json(%{error: "authorization_pending"})

      {:ok, token_data} ->
        json(conn, token_data)

      {:error, :slow_down} ->
        conn
        |> put_status(428)
        |> json(%{error: "slow_down"})

      {:error, :expired_token} ->
        conn
        |> put_status(:gone)
        |> json(%{error: "expired_token"})

      {:error, :access_denied} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "access_denied"})

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_grant"})
    end
  end

  def poll_token(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_request", message: "device_code and grant_type are required"})
  end
end
