defmodule Loomkin.Federation.DidDocument do
  @moduledoc """
  Builds DID documents following the `did:web` specification.

  A DID document advertises the instance's public key and service endpoint,
  enabling signature verification and discovery by other instances.

  ## DID Format

  - Domain-level: `did:web:loomkin.dev`
  - User-level: `did:web:loomkin.dev:brandon`

  ## Served at

  - `/.well-known/did.json` for the domain-level DID
  - `/:username/did.json` for user-level DIDs (future)
  """

  alias Loomkin.Federation.Identity

  @doc """
  Build a DID document for the instance.

  Accepts a keyword list or map with:
  - `:domain` (required) - the domain for the DID (e.g. "loomkin.dev")
  - `:public_key` (required) - raw Ed25519 public key bytes
  - `:service_endpoint` (optional) - PDS WebSocket endpoint URL

  Returns a map suitable for JSON encoding.
  """
  @spec build(keyword() | map()) :: map()
  def build(opts) when is_list(opts) do
    opts |> Map.new() |> build()
  end

  def build(%{domain: domain, public_key: public_key} = opts) do
    did = did_for_domain(domain)

    %{
      "@context" => [
        "https://www.w3.org/ns/did/v1",
        "https://w3id.org/security/suites/ed25519-2020/v1"
      ],
      "id" => did,
      "verificationMethod" => [
        %{
          "id" => "#{did}#key-1",
          "type" => "Ed25519VerificationKey2020",
          "controller" => did,
          "publicKeyMultibase" => Identity.encode_multibase(public_key)
        }
      ],
      "authentication" => ["#{did}#key-1"],
      "assertionMethod" => ["#{did}#key-1"]
    }
    |> maybe_put_service(did, opts)
  end

  @doc """
  Build a DID document for a specific user under a domain.

  Accepts the same options as `build/1` plus:
  - `:username` (required) - the user's handle

  The DID becomes `did:web:<domain>:<username>`.
  """
  @spec build_for_user(keyword() | map()) :: map()
  def build_for_user(opts) when is_list(opts) do
    opts |> Map.new() |> build_for_user()
  end

  def build_for_user(%{domain: domain, username: username, public_key: public_key} = opts) do
    did = did_for_user(domain, username)

    %{
      "@context" => [
        "https://www.w3.org/ns/did/v1",
        "https://w3id.org/security/suites/ed25519-2020/v1"
      ],
      "id" => did,
      "verificationMethod" => [
        %{
          "id" => "#{did}#key-1",
          "type" => "Ed25519VerificationKey2020",
          "controller" => did,
          "publicKeyMultibase" => Identity.encode_multibase(public_key)
        }
      ],
      "authentication" => ["#{did}#key-1"],
      "assertionMethod" => ["#{did}#key-1"]
    }
    |> maybe_put_service(did, opts)
  end

  @doc """
  Construct the `did:web` identifier for a domain.

  Colons in the domain are encoded as per the did:web spec
  (ports use `%3A`).

  ## Examples

      iex> Loomkin.Federation.DidDocument.did_for_domain("loomkin.dev")
      "did:web:loomkin.dev"

      iex> Loomkin.Federation.DidDocument.did_for_domain("localhost:4200")
      "did:web:localhost%3A4200"
  """
  @spec did_for_domain(String.t()) :: String.t()
  def did_for_domain(domain) do
    encoded = String.replace(domain, ":", "%3A")
    "did:web:#{encoded}"
  end

  @doc """
  Construct the `did:web` identifier for a user under a domain.

  ## Examples

      iex> Loomkin.Federation.DidDocument.did_for_user("loomkin.dev", "brandon")
      "did:web:loomkin.dev:brandon"
  """
  @spec did_for_user(String.t(), String.t()) :: String.t()
  def did_for_user(domain, username) do
    "#{did_for_domain(domain)}:#{username}"
  end

  # -- Private --

  defp maybe_put_service(doc, _did, opts) when not is_map_key(opts, :service_endpoint), do: doc
  defp maybe_put_service(doc, _did, %{service_endpoint: nil}), do: doc

  defp maybe_put_service(doc, did, %{service_endpoint: endpoint}) do
    Map.put(doc, "service", [
      %{
        "id" => "#{did}#pds",
        "type" => "LoomkinPDS",
        "serviceEndpoint" => endpoint
      }
    ])
  end
end
