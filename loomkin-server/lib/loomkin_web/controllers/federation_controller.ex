defmodule LoomkinWeb.FederationController do
  @moduledoc """
  Serves federation-related endpoints for DID document discovery.

  - `GET /.well-known/did.json` - instance-level DID document
  """

  use LoomkinWeb, :controller

  require Logger

  alias Loomkin.Federation.DidDocument
  alias Loomkin.Federation.Identity

  @doc """
  Serve the instance-level DID document at `/.well-known/did.json`.

  Uses the cached keypair (loaded at startup via `:persistent_term`) and
  builds the DID document using the configured domain.
  """
  def did_document(conn, _params) do
    domain = Identity.domain()

    case Identity.cached_keypair() do
      {:ok, keypair} ->
        doc =
          DidDocument.build(
            domain: domain,
            public_key: keypair.public
          )

        conn
        |> put_resp_content_type("application/did+ld+json")
        |> json(doc)

      {:error, reason} ->
        Logger.error("Failed to load identity keypair: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "identity unavailable"})
    end
  end
end
