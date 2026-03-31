defmodule Loomkin.Relay.Macaroon do
  @moduledoc """
  Macaroon-based authentication tokens for relay daemon connections.

  Implements the macaroon construction from Birgisson et al. using HMAC-SHA256:
  each caveat is chained into the signature, so tokens can be attenuated
  (restricted) by anyone holding the token but only verified by the holder
  of the root key.

  ## Caveat format

  First-party caveats are predicate strings in `key = value` format.
  Supported predicates:

    * `user_id = <id>` — scopes to a specific user
    * `workspace_id = <id>` — scopes to a specific workspace
    * `role = owner|collaborator|observer` — permission level
    * `paths = ["/lib/**"]` — file access restrictions (JSON array)
    * `expires = <iso8601>` — expiration timestamp
    * `instance = <url>` — which relay instance issued the token
  """

  @type t :: %__MODULE__{
          location: String.t(),
          identifier: String.t(),
          caveats: [String.t()],
          signature: binary()
        }

  @enforce_keys [:location, :identifier, :signature]
  defstruct [:location, :identifier, :signature, caveats: []]

  @valid_roles ~w(owner collaborator observer)
  @required_caveats ~w(user_id workspace_id role expires)

  # --- Public API ---

  @doc """
  Mint a new daemon token for the given user and workspace.

  Options:
    * `:role` — one of `"owner"`, `"collaborator"`, `"observer"` (default `"owner"`)
    * `:paths` — list of path globs for file access restrictions
    * `:ttl` — token time-to-live in seconds (default 86400 = 24h)
    * `:instance` — relay instance URL to bind the token to

  Returns a serialized token string.
  """
  @spec mint_daemon_token(integer() | String.t(), String.t(), keyword()) :: String.t()
  def mint_daemon_token(user_id, workspace_id, opts \\ []) do
    role = Keyword.get(opts, :role, "owner")

    unless role in @valid_roles do
      raise ArgumentError,
            "invalid role #{inspect(role)}, expected one of #{inspect(@valid_roles)}"
    end

    paths = Keyword.get(opts, :paths, nil)
    ttl = Keyword.get(opts, :ttl, 86_400)
    instance = Keyword.get(opts, :instance, nil)

    expires =
      DateTime.utc_now()
      |> DateTime.add(ttl, :second)
      |> DateTime.to_iso8601()

    caveats =
      [
        "user_id = #{user_id}",
        "workspace_id = #{workspace_id}",
        "role = #{role}",
        "expires = #{expires}"
      ]
      |> maybe_add_paths(paths)
      |> maybe_add_instance(instance)

    location = instance || "loomkin-local"
    identifier = generate_identifier(user_id, workspace_id)

    create(location, identifier, root_key())
    |> attenuate(caveats)
    |> serialize()
  end

  @doc """
  Create a root macaroon with the given location, identifier, and key.

  The initial signature is `HMAC-SHA256(key, identifier)`.
  """
  @spec create(String.t(), String.t(), binary()) :: t()
  def create(location, identifier, key) when is_binary(location) and is_binary(identifier) do
    sig = hmac(derive_key(key), identifier)

    %__MODULE__{
      location: location,
      identifier: identifier,
      caveats: [],
      signature: sig
    }
  end

  @doc """
  Add first-party caveats to an existing macaroon.

  Each caveat is chained into the signature: `sig' = HMAC(sig, caveat)`.
  This means anyone holding the token can add caveats (making it more
  restrictive) but cannot remove them.
  """
  @spec attenuate(t(), [String.t()]) :: t()
  def attenuate(%__MODULE__{} = macaroon, caveats) when is_list(caveats) do
    {new_caveats_reversed, new_sig} =
      Enum.reduce(caveats, {[], macaroon.signature}, fn caveat, {acc_caveats, sig} ->
        {[caveat | acc_caveats], hmac(sig, caveat)}
      end)

    # Reverse to restore forward order — HMAC chain was computed left-to-right above
    all_caveats = macaroon.caveats ++ Enum.reverse(new_caveats_reversed)
    %{macaroon | caveats: all_caveats, signature: new_sig}
  end

  @doc """
  Verify a serialized token string.

  Deserializes the token and checks:
  1. The HMAC chain is valid (signature matches re-derivation from root key)
  2. All caveats are satisfied (expiration, user, workspace, role, etc.)

  Returns `{:ok, claims}` on success where `claims` is a map of parsed
  caveat key-value pairs, or `{:error, reason}` on failure.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, atom() | tuple()}
  def verify(serialized_token) when is_binary(serialized_token) do
    with {:ok, macaroon} <- deserialize(serialized_token),
         :ok <- verify_signature(macaroon),
         {:ok, claims} <- verify_caveats(macaroon),
         :ok <- check_required_caveats(claims) do
      {:ok, claims}
    end
  end

  @doc """
  Serialize a macaroon struct to a URL-safe base64 string.
  """
  @spec serialize(t()) :: String.t()
  def serialize(%__MODULE__{} = macaroon) do
    %{
      "v" => 1,
      "l" => macaroon.location,
      "i" => macaroon.identifier,
      "c" => macaroon.caveats,
      "s" => Base.url_encode64(macaroon.signature, padding: false)
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Deserialize a URL-safe base64 string back to a macaroon struct.
  """
  @spec deserialize(String.t()) :: {:ok, t()} | {:error, :invalid_token}
  def deserialize(token) when is_binary(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, map} <- Jason.decode(json),
         {:ok, sig} <- Base.url_decode64(map["s"] || "", padding: false) do
      {:ok,
       %__MODULE__{
         location: map["l"],
         identifier: map["i"],
         caveats: map["c"] || [],
         signature: sig
       }}
    else
      _ -> {:error, :invalid_token}
    end
  end

  # --- Private ---

  defp verify_signature(%__MODULE__{} = macaroon) do
    expected_sig =
      create(macaroon.location, macaroon.identifier, root_key())
      |> attenuate(macaroon.caveats)
      |> Map.get(:signature)

    if secure_compare(macaroon.signature, expected_sig) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_caveats(%__MODULE__{caveats: caveats}) do
    Enum.reduce_while(caveats, {:ok, %{}}, fn caveat, {:ok, acc} ->
      case parse_caveat(caveat) do
        {:ok, key, value} ->
          case verify_single_caveat(key, value) do
            :ok -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, _} = err -> {:halt, err}
          end

        :error ->
          {:halt, {:error, {:invalid_caveat_format, caveat}}}
      end
    end)
  end

  defp check_required_caveats(claims) do
    missing = Enum.filter(@required_caveats, fn key -> not Map.has_key?(claims, key) end)

    if missing == [] do
      :ok
    else
      {:error, {:missing_caveats, missing}}
    end
  end

  defp parse_caveat(caveat) when is_binary(caveat) do
    case String.split(caveat, " = ", parts: 2) do
      [key, value] ->
        {:ok, String.trim(key), String.trim(value)}

      _ ->
        :error
    end
  end

  defp verify_single_caveat("expires", iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, expires, _offset} ->
        if DateTime.compare(DateTime.utc_now(), expires) == :lt do
          :ok
        else
          {:error, :token_expired}
        end

      _ ->
        {:error, :invalid_expiration}
    end
  end

  defp verify_single_caveat("role", role) when role in @valid_roles, do: :ok
  defp verify_single_caveat("role", _), do: {:error, :invalid_role}

  defp verify_single_caveat("user_id", value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> :ok
      _ -> {:error, :invalid_user_id}
    end
  end

  defp verify_single_caveat("workspace_id", value) do
    if String.trim(value) != "" do
      :ok
    else
      {:error, :empty_workspace_id}
    end
  end

  # Advisory / deferred-enforcement caveats: `instance` identifies the issuing relay
  # and `paths` restricts file access. Both are enforced at the application layer
  # (e.g. the file-access middleware), not during token verification itself.
  defp verify_single_caveat(key, _value) when key in ~w(instance paths), do: :ok

  defp verify_single_caveat(key, _value), do: {:error, {:unknown_caveat, key}}

  defp hmac(key, data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  defp derive_key(key) do
    hmac("loomkin-macaroon-key-v1", key)
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp root_key do
    base =
      Application.get_env(:loomkin, LoomkinWeb.Endpoint)[:secret_key_base] ||
        raise "secret_key_base not configured — cannot sign macaroon tokens"

    :crypto.mac(:hmac, :sha256, base, "loomkin:relay:macaroon:root-key-v1")
  end

  defp generate_identifier(user_id, workspace_id) do
    random = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    "loomkin-daemon:#{user_id}:#{workspace_id}:#{random}"
  end

  defp maybe_add_paths(caveats, nil), do: caveats
  defp maybe_add_paths(caveats, []), do: caveats

  defp maybe_add_paths(caveats, paths) when is_list(paths) do
    caveats ++ ["paths = #{Jason.encode!(paths)}"]
  end

  defp maybe_add_instance(caveats, nil), do: caveats

  defp maybe_add_instance(caveats, instance) when is_binary(instance) do
    caveats ++ ["instance = #{instance}"]
  end
end
