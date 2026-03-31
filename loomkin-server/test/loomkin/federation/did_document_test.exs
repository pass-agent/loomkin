defmodule Loomkin.Federation.DidDocumentTest do
  use ExUnit.Case, async: true

  alias Loomkin.Federation.DidDocument
  alias Loomkin.Federation.Identity

  setup do
    keypair = Identity.generate_keypair()
    %{keypair: keypair}
  end

  describe "did_for_domain/1" do
    test "simple domain" do
      assert DidDocument.did_for_domain("loomkin.dev") == "did:web:loomkin.dev"
    end

    test "domain with port encodes colon" do
      assert DidDocument.did_for_domain("localhost:4200") == "did:web:localhost%3A4200"
    end

    test "subdomain" do
      assert DidDocument.did_for_domain("loom.mycompany.com") == "did:web:loom.mycompany.com"
    end
  end

  describe "did_for_user/2" do
    test "user under domain" do
      assert DidDocument.did_for_user("loomkin.dev", "brandon") ==
               "did:web:loomkin.dev:brandon"
    end

    test "user under domain with port" do
      assert DidDocument.did_for_user("localhost:4200", "alice") ==
               "did:web:localhost%3A4200:alice"
    end
  end

  describe "build/1" do
    test "produces valid DID document structure", %{keypair: kp} do
      doc = DidDocument.build(domain: "loomkin.dev", public_key: kp.public)

      assert doc["@context"] == [
               "https://www.w3.org/ns/did/v1",
               "https://w3id.org/security/suites/ed25519-2020/v1"
             ]

      assert doc["id"] == "did:web:loomkin.dev"
      assert is_list(doc["verificationMethod"])
      assert length(doc["verificationMethod"]) == 1

      [vm] = doc["verificationMethod"]
      assert vm["id"] == "did:web:loomkin.dev#key-1"
      assert vm["type"] == "Ed25519VerificationKey2020"
      assert vm["controller"] == "did:web:loomkin.dev"
      assert String.starts_with?(vm["publicKeyMultibase"], "z")

      assert doc["authentication"] == ["did:web:loomkin.dev#key-1"]
      assert doc["assertionMethod"] == ["did:web:loomkin.dev#key-1"]
    end

    test "includes service endpoint when provided", %{keypair: kp} do
      doc =
        DidDocument.build(
          domain: "loomkin.dev",
          public_key: kp.public,
          service_endpoint: "wss://brandon-mac.local:4000"
        )

      assert is_list(doc["service"])
      [service] = doc["service"]
      assert service["id"] == "did:web:loomkin.dev#pds"
      assert service["type"] == "LoomkinPDS"
      assert service["serviceEndpoint"] == "wss://brandon-mac.local:4000"
    end

    test "omits service when no endpoint provided", %{keypair: kp} do
      doc = DidDocument.build(domain: "loomkin.dev", public_key: kp.public)
      refute Map.has_key?(doc, "service")
    end

    test "accepts map opts", %{keypair: kp} do
      doc = DidDocument.build(%{domain: "loomkin.dev", public_key: kp.public})
      assert doc["id"] == "did:web:loomkin.dev"
    end

    test "public key can be decoded from the document", %{keypair: kp} do
      doc = DidDocument.build(domain: "loomkin.dev", public_key: kp.public)
      [vm] = doc["verificationMethod"]

      assert {:ok, decoded_key} = Identity.decode_multibase(vm["publicKeyMultibase"])
      assert decoded_key == kp.public
    end
  end

  describe "build_for_user/1" do
    test "produces user-level DID document", %{keypair: kp} do
      doc =
        DidDocument.build_for_user(
          domain: "loomkin.dev",
          username: "brandon",
          public_key: kp.public
        )

      assert doc["id"] == "did:web:loomkin.dev:brandon"

      [vm] = doc["verificationMethod"]
      assert vm["id"] == "did:web:loomkin.dev:brandon#key-1"
      assert vm["controller"] == "did:web:loomkin.dev:brandon"
    end

    test "includes service endpoint when provided", %{keypair: kp} do
      doc =
        DidDocument.build_for_user(
          domain: "loomkin.dev",
          username: "alice",
          public_key: kp.public,
          service_endpoint: "wss://alice-laptop.local:4000"
        )

      [service] = doc["service"]
      assert service["serviceEndpoint"] == "wss://alice-laptop.local:4000"
    end
  end

  describe "DID document is JSON-serializable" do
    test "can be encoded to JSON without error", %{keypair: kp} do
      doc =
        DidDocument.build(
          domain: "loomkin.dev",
          public_key: kp.public,
          service_endpoint: "wss://example.com:4000"
        )

      assert {:ok, json} = Jason.encode(doc)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["id"] == "did:web:loomkin.dev"
    end
  end
end
