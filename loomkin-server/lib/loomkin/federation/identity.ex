defmodule Loomkin.Federation.Identity do
  @moduledoc """
  Cryptographic identity for a Loomkin instance using Ed25519 keypairs.

  Each instance gets a persistent Ed25519 keypair used for:
  - Signing records (snippets, skills, sessions)
  - Building a `did:web` DID document
  - Future federation and AT Protocol compatibility

  Keys are stored on disk at a configurable path (default: `priv/keys/`).
  The keypair is generated on first access and persisted for subsequent boots.
  """

  require Logger

  alias Loomkin.Federation.Base58

  @type keypair :: %{public: binary(), private: binary()}

  @doc """
  Generate a fresh Ed25519 keypair.

  Returns `%{public: <<...>>, private: <<...>>}` with 32-byte raw keys.
  """
  @spec generate_keypair() :: keypair()
  def generate_keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, private: private}
  end

  @doc """
  Load the keypair into `:persistent_term` for fast subsequent access.

  Call this at application startup to avoid disk I/O on every request.
  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec ensure_loaded() :: :ok | {:error, term()}
  def ensure_loaded do
    case get_or_create_keypair() do
      {:ok, keypair} ->
        :persistent_term.put({__MODULE__, :keypair}, keypair)
        :ok

      error ->
        error
    end
  end

  @doc """
  Return the cached keypair from `:persistent_term`, loading it on first call.

  Avoids disk I/O on every request by caching in `:persistent_term`.
  Returns `{:ok, keypair}` on success, `{:error, reason}` on failure.
  """
  @spec cached_keypair() :: {:ok, keypair()} | {:error, term()}
  def cached_keypair do
    case :persistent_term.get({__MODULE__, :keypair}, nil) do
      nil ->
        case get_or_create_keypair() do
          {:ok, keypair} ->
            :persistent_term.put({__MODULE__, :keypair}, keypair)
            {:ok, keypair}

          {:error, _reason} = error ->
            error
        end

      keypair ->
        {:ok, keypair}
    end
  end

  @doc """
  Return the configured domain for this instance.

  Defaults to `"localhost"` when not configured.
  """
  @spec domain() :: String.t()
  def domain do
    config = Application.get_env(:loomkin, __MODULE__, [])
    Keyword.get(config, :domain, "localhost")
  end

  @doc """
  Load an existing keypair from disk, or generate and persist a new one.

  The storage path is read from application config:

      config :loomkin, Loomkin.Federation.Identity,
        key_path: "priv/keys/"

  Returns `{:ok, keypair}` on success, `{:error, reason}` on failure.
  """
  @spec get_or_create_keypair() :: {:ok, keypair()} | {:error, term()}
  def get_or_create_keypair do
    key_dir = key_path()

    case load_keypair(key_dir) do
      {:ok, keypair} ->
        {:ok, keypair}

      :not_found ->
        generate_and_store(key_dir)
    end
  end

  @doc """
  Sign a binary payload with the instance's Ed25519 private key.

  Returns the raw 64-byte signature.
  """
  @spec sign(binary(), binary()) :: binary()
  def sign(payload, private_key) when is_binary(payload) and is_binary(private_key) do
    :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
  end

  @doc """
  Verify a signature against a payload and public key.

  Returns `true` if the signature is valid, `false` otherwise.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(payload, signature, public_key)
      when is_binary(payload) and is_binary(signature) and is_binary(public_key) do
    :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])
  end

  @doc """
  Sign an arbitrary map record.

  JSON-encodes the map with sorted keys for deterministic output,
  then signs with the given private key.

  Returns `{encoded_record, signature}`.
  """
  @spec sign_record(map(), binary()) :: {binary(), binary()}
  def sign_record(record, private_key) when is_map(record) and is_binary(private_key) do
    encoded = canonical_encode(record)
    signature = sign(encoded, private_key)
    {encoded, signature}
  end

  @doc """
  Verify a signed record against a signature and public key.

  The record can be a binary (already JSON-encoded) or a map
  (which will be JSON-encoded with sorted keys).

  Returns `true` if the signature is valid, `false` otherwise.
  """
  @spec verify_record(binary() | map(), binary(), binary()) :: boolean()
  def verify_record(record, signature, public_key) when is_binary(record) do
    verify(record, signature, public_key)
  end

  def verify_record(record, signature, public_key) when is_map(record) do
    encoded = canonical_encode(record)
    verify(encoded, signature, public_key)
  end

  @doc """
  Encode a raw public key as a multibase-encoded string.

  Uses the `z` prefix (base58btc) per the did:web / Ed25519VerificationKey2020 spec.
  The multicodec prefix for Ed25519 public keys is `0xed01`.
  """
  @spec encode_multibase(binary()) :: String.t()
  def encode_multibase(public_key) when is_binary(public_key) do
    # Multicodec prefix for ed25519-pub: 0xed 0x01
    prefixed = <<0xED, 0x01>> <> public_key
    "z" <> Base58.encode(prefixed)
  end

  @doc """
  Decode a multibase-encoded public key back to raw bytes.

  Expects the `z` prefix (base58btc) with the ed25519 multicodec prefix.
  Returns `{:ok, public_key}` or `{:error, reason}`.
  """
  @spec decode_multibase(String.t()) :: {:ok, binary()} | {:error, term()}
  def decode_multibase("z" <> encoded) do
    with {:ok, decoded} <- Base58.decode(encoded) do
      case decoded do
        <<0xED, 0x01, public_key::binary-size(32)>> ->
          {:ok, public_key}

        <<0xED, 0x01, _rest::binary>> ->
          {:error, :invalid_key_length}

        _other ->
          {:error, :invalid_multicodec_prefix}
      end
    end
  end

  def decode_multibase(_other), do: {:error, :invalid_multibase_prefix}

  # -- Private --

  defp key_path do
    config = Application.get_env(:loomkin, __MODULE__, [])
    Keyword.get(config, :key_path, "priv/keys")
  end

  defp load_keypair(dir) do
    pub_path = Path.join(dir, "identity.pub")
    priv_path = Path.join(dir, "identity.key")

    if File.exists?(pub_path) and File.exists?(priv_path) do
      with {:ok, public} <- File.read(pub_path),
           {:ok, private} <- File.read(priv_path) do
        {:ok, %{public: public, private: private}}
      end
    else
      :not_found
    end
  end

  defp generate_and_store(dir) do
    keypair = generate_keypair()
    priv_path = Path.join(dir, "identity.key")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "identity.pub"), keypair.public),
         :ok <- File.write(priv_path, keypair.private),
         :ok <- File.chmod(priv_path, 0o600) do
      Logger.info("Generated new Ed25519 identity keypair at #{dir}")
      {:ok, keypair}
    else
      {:error, reason} ->
        Logger.error("Failed to store identity keypair: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Produces deterministic JSON by recursively sorting map keys.
  # Uses Jason.OrderedObject to preserve insertion order after sorting.
  defp canonical_encode(value) when is_map(value) and not is_struct(value) do
    ordered =
      value
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> {k, canonical_encode(v)} end)
      |> Jason.OrderedObject.new()

    Jason.encode!(ordered)
  end

  defp canonical_encode(value) when is_list(value) do
    Enum.map(value, &canonical_encode/1)
  end

  defp canonical_encode(value), do: value
end
