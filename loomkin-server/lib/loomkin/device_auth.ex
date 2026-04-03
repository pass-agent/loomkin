defmodule Loomkin.DeviceAuth do
  @moduledoc """
  Business logic for OAuth 2.0 Device Authorization Grant (RFC 8628).
  Used by the CLI to authenticate users via the browser.
  """

  import Ecto.Query

  alias Loomkin.Accounts
  alias Loomkin.Repo
  alias Loomkin.Schemas.DeviceCode

  @user_code_alphabet ~c"BCDFGHJKLMNPQRSTVWXYZ2345679"
  @user_code_length 8
  @device_code_expires_in 900

  @doc """
  Creates a new device authorization request.
  Returns a map with device_code, user_code, verification URIs, etc.
  """
  def create_device_code(client_id, scope \\ "vault:read vault:write") do
    device_code = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    user_code = generate_user_code()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@device_code_expires_in, :second)
      |> DateTime.truncate(:second)

    attrs = %{
      device_code: device_code,
      user_code: user_code,
      client_id: client_id,
      scope: scope,
      expires_at: expires_at
    }

    case %DeviceCode{} |> DeviceCode.changeset(attrs) |> Repo.insert() do
      {:ok, record} ->
        base_url = verification_base_url()

        {:ok,
         %{
           device_code: record.device_code,
           user_code: format_user_code(record.user_code),
           verification_uri: "#{base_url}/device",
           verification_uri_complete:
             "#{base_url}/device?user_code=#{format_user_code(record.user_code)}",
           expires_in: @device_code_expires_in,
           interval: record.interval
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Poll for the status of a device code.
  Returns appropriate result based on current status.
  """
  def poll_device_code(device_code) do
    case Repo.get_by(DeviceCode, device_code: device_code) do
      nil ->
        {:error, :invalid_grant}

      %DeviceCode{status: "pending"} = dc ->
        now = DateTime.utc_now()

        cond do
          DateTime.compare(now, dc.expires_at) == :gt ->
            dc |> DeviceCode.changeset(%{status: "expired"}) |> Repo.update()
            {:error, :expired_token}

          too_fast?(dc, now) ->
            {:error, :slow_down}

          true ->
            dc
            |> DeviceCode.changeset(%{last_polled_at: DateTime.truncate(now, :second)})
            |> Repo.update()

            {:ok, :pending}
        end

      %DeviceCode{status: "approved", user_id: user_id} = dc when not is_nil(user_id) ->
        user = Accounts.get_user!(user_id)
        token = Accounts.generate_user_session_token(user)
        Repo.delete!(dc)

        {:ok,
         %{
           access_token: Base.url_encode64(token),
           token_type: "Bearer",
           expires_in: 31_536_000,
           scope: dc.scope
         }}

      %DeviceCode{status: "denied"} ->
        {:error, :access_denied}

      %DeviceCode{status: "expired"} ->
        {:error, :expired_token}

      _ ->
        {:error, :invalid_grant}
    end
  end

  @doc """
  Approve a device code, linking it to the authenticated user.
  """
  def approve_device_code(user_code, user_id) do
    case lookup_by_user_code(user_code) do
      {:ok, dc} ->
        dc
        |> DeviceCode.changeset(%{status: "approved", user_id: user_id})
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deny a device code request.
  """
  def deny_device_code(user_code) do
    case lookup_by_user_code(user_code) do
      {:ok, dc} ->
        dc
        |> DeviceCode.changeset(%{status: "denied"})
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Look up a pending, non-expired device code by user_code.
  Accepts both formatted (XXXX-XXXX) and raw (XXXXXXXX) codes.
  """
  def lookup_by_user_code(user_code) do
    normalized = user_code |> String.replace("-", "") |> String.upcase()
    now = DateTime.utc_now()

    query =
      from(dc in DeviceCode,
        where: dc.user_code == ^normalized and dc.status == "pending" and dc.expires_at > ^now
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      dc -> {:ok, dc}
    end
  end

  # --- Private helpers ---

  defp too_fast?(%DeviceCode{last_polled_at: nil}, _now), do: false

  defp too_fast?(%DeviceCode{last_polled_at: last, interval: interval}, now) do
    DateTime.diff(now, last, :second) < interval
  end

  defp generate_user_code do
    alphabet = @user_code_alphabet

    1..@user_code_length
    |> Enum.map(fn _ -> Enum.random(alphabet) end)
    |> List.to_string()
  end

  defp format_user_code(code) when byte_size(code) == 8 do
    <<first::binary-size(4), rest::binary-size(4)>> = code
    "#{first}-#{rest}"
  end

  defp format_user_code(code), do: code

  defp verification_base_url do
    if Application.get_env(:loomkin, :multi_tenant) do
      Application.get_env(:loomkin, :verification_base_url, "https://loomkin.dev")
    else
      LoomkinWeb.Endpoint.url()
    end
  end
end
