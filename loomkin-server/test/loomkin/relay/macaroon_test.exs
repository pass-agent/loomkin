defmodule Loomkin.Relay.MacaroonTest do
  use ExUnit.Case, async: true

  alias Loomkin.Relay.Macaroon

  describe "create/3" do
    test "produces a macaroon struct with correct fields" do
      mac = Macaroon.create("https://relay.loomkin.dev", "test-id", "secret-key")

      assert %Macaroon{} = mac
      assert mac.location == "https://relay.loomkin.dev"
      assert mac.identifier == "test-id"
      assert mac.caveats == []
      assert is_binary(mac.signature)
      assert byte_size(mac.signature) == 32
    end
  end

  describe "attenuate/2" do
    test "adds caveats to the macaroon" do
      mac =
        Macaroon.create("loc", "id", "key")
        |> Macaroon.attenuate(["user_id = 42", "role = owner"])

      assert length(mac.caveats) == 2
      assert "user_id = 42" in mac.caveats
      assert "role = owner" in mac.caveats
    end

    test "each caveat changes the signature" do
      mac = Macaroon.create("loc", "id", "key")
      mac1 = Macaroon.attenuate(mac, ["caveat_a = 1"])
      mac2 = Macaroon.attenuate(mac, ["caveat_b = 2"])

      assert mac.signature != mac1.signature
      assert mac1.signature != mac2.signature
    end

    test "caveat ordering matters for signature" do
      mac = Macaroon.create("loc", "id", "key")
      mac_ab = Macaroon.attenuate(mac, ["a = 1", "b = 2"])
      mac_ba = Macaroon.attenuate(mac, ["b = 2", "a = 1"])

      assert mac_ab.signature != mac_ba.signature
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "roundtrip preserves all fields" do
      mac =
        Macaroon.create("https://relay.loomkin.dev", "daemon:1:ws-1:abc", "secret")
        |> Macaroon.attenuate(["user_id = 1", "workspace_id = ws-1", "role = owner"])

      serialized = Macaroon.serialize(mac)
      assert is_binary(serialized)

      assert {:ok, deserialized} = Macaroon.deserialize(serialized)
      assert deserialized.location == mac.location
      assert deserialized.identifier == mac.identifier
      assert deserialized.caveats == mac.caveats
      assert deserialized.signature == mac.signature
    end

    test "returns error for invalid base64" do
      assert {:error, :invalid_token} = Macaroon.deserialize("not-valid!!!")
    end

    test "returns error for invalid json inside base64" do
      token = Base.url_encode64("not json", padding: false)
      assert {:error, :invalid_token} = Macaroon.deserialize(token)
    end
  end

  describe "mint_daemon_token/3" do
    test "produces a serialized token string" do
      token = Macaroon.mint_daemon_token(42, "ws-123")

      assert is_binary(token)
      assert String.length(token) > 0
    end

    test "token contains expected caveats" do
      token = Macaroon.mint_daemon_token(42, "ws-123", role: "collaborator")

      assert {:ok, mac} = Macaroon.deserialize(token)
      assert Enum.any?(mac.caveats, &String.starts_with?(&1, "user_id = 42"))
      assert Enum.any?(mac.caveats, &String.starts_with?(&1, "workspace_id = ws-123"))
      assert Enum.any?(mac.caveats, &String.starts_with?(&1, "role = collaborator"))
      assert Enum.any?(mac.caveats, &String.starts_with?(&1, "expires = "))
    end

    test "includes paths caveat when provided" do
      token = Macaroon.mint_daemon_token(1, "ws-1", paths: ["/lib/**", "/test/**"])

      assert {:ok, mac} = Macaroon.deserialize(token)
      paths_caveat = Enum.find(mac.caveats, &String.starts_with?(&1, "paths = "))
      assert paths_caveat
      assert paths_caveat =~ "/lib/**"
      assert paths_caveat =~ "/test/**"
    end

    test "includes instance caveat when provided" do
      token = Macaroon.mint_daemon_token(1, "ws-1", instance: "https://relay.loomkin.dev")

      assert {:ok, mac} = Macaroon.deserialize(token)
      assert "instance = https://relay.loomkin.dev" in mac.caveats
    end

    test "uses custom ttl" do
      token = Macaroon.mint_daemon_token(1, "ws-1", ttl: 60)

      assert {:ok, mac} = Macaroon.deserialize(token)
      expires_caveat = Enum.find(mac.caveats, &String.starts_with?(&1, "expires = "))
      [_, iso_str] = String.split(expires_caveat, " = ", parts: 2)
      {:ok, expires, _} = DateTime.from_iso8601(iso_str)

      # Should expire within ~65 seconds from now (allow 5s slack for test execution)
      diff = DateTime.diff(expires, DateTime.utc_now(), :second)
      assert diff > 0
      assert diff <= 65
    end

    test "raises ArgumentError for invalid role" do
      assert_raise ArgumentError, ~r/invalid role/, fn ->
        Macaroon.mint_daemon_token(1, "ws-1", role: "superadmin")
      end
    end
  end

  describe "verify/1" do
    test "succeeds for a valid token" do
      token = Macaroon.mint_daemon_token(42, "ws-abc", role: "owner")

      assert {:ok, claims} = Macaroon.verify(token)
      assert claims["user_id"] == "42"
      assert claims["workspace_id"] == "ws-abc"
      assert claims["role"] == "owner"
      assert Map.has_key?(claims, "expires")
    end

    test "fails for expired tokens" do
      token = Macaroon.mint_daemon_token(1, "ws-1", ttl: -1)

      assert {:error, :token_expired} = Macaroon.verify(token)
    end

    test "fails for tampered signature" do
      token = Macaroon.mint_daemon_token(1, "ws-1")
      {:ok, mac} = Macaroon.deserialize(token)

      # Tamper with the signature
      tampered = %{mac | signature: :crypto.strong_rand_bytes(32)}
      tampered_token = Macaroon.serialize(tampered)

      assert {:error, :invalid_signature} = Macaroon.verify(tampered_token)
    end

    test "fails for tampered caveats" do
      token = Macaroon.mint_daemon_token(1, "ws-1", role: "observer")
      {:ok, mac} = Macaroon.deserialize(token)

      # Change observer to owner — should break signature
      tampered_caveats =
        Enum.map(mac.caveats, fn
          "role = observer" -> "role = owner"
          c -> c
        end)

      tampered = %{mac | caveats: tampered_caveats}
      tampered_token = Macaroon.serialize(tampered)

      assert {:error, :invalid_signature} = Macaroon.verify(tampered_token)
    end

    test "fails for added caveats without re-signing" do
      token = Macaroon.mint_daemon_token(1, "ws-1")
      {:ok, mac} = Macaroon.deserialize(token)

      # Add a caveat without updating the signature
      injected = %{mac | caveats: mac.caveats ++ ["role = owner"]}
      injected_token = Macaroon.serialize(injected)

      assert {:error, :invalid_signature} = Macaroon.verify(injected_token)
    end

    test "fails for removed caveats" do
      token = Macaroon.mint_daemon_token(1, "ws-1", role: "owner")
      {:ok, mac} = Macaroon.deserialize(token)

      # Remove the role caveat
      stripped = %{mac | caveats: Enum.reject(mac.caveats, &String.starts_with?(&1, "role"))}
      stripped_token = Macaroon.serialize(stripped)

      assert {:error, :invalid_signature} = Macaroon.verify(stripped_token)
    end

    test "fails for invalid role" do
      # Build a macaroon with an invalid role by going through the low-level API
      mac =
        Macaroon.create("loomkin-local", "test-id", root_key())
        |> Macaroon.attenuate([
          "user_id = 1",
          "workspace_id = ws-1",
          "role = superadmin",
          "expires = #{future_expiry()}"
        ])

      token = Macaroon.serialize(mac)

      assert {:error, :invalid_role} = Macaroon.verify(token)
    end

    test "fails for completely invalid token" do
      assert {:error, :invalid_token} = Macaroon.verify("garbage-data")
    end

    test "fails for empty token" do
      assert {:error, :invalid_token} = Macaroon.verify("")
    end

    test "succeeds with all caveat types" do
      token =
        Macaroon.mint_daemon_token(99, "ws-prod",
          role: "collaborator",
          paths: ["/lib/**"],
          instance: "https://relay.loomkin.dev",
          ttl: 3600
        )

      assert {:ok, claims} = Macaroon.verify(token)
      assert claims["user_id"] == "99"
      assert claims["workspace_id"] == "ws-prod"
      assert claims["role"] == "collaborator"
      assert claims["paths"] == ~s([\"/lib/**\"])
      assert claims["instance"] == "https://relay.loomkin.dev"
    end

    test "different workspaces produce different tokens" do
      token_a = Macaroon.mint_daemon_token(1, "ws-a")
      token_b = Macaroon.mint_daemon_token(1, "ws-b")

      assert token_a != token_b
    end

    test "rejects unknown caveats" do
      mac =
        Macaroon.create("loomkin-local", "test-id", root_key())
        |> Macaroon.attenuate([
          "user_id = 1",
          "workspace_id = ws-1",
          "role = owner",
          "expires = #{future_expiry()}",
          "unknown_thing = bad"
        ])

      token = Macaroon.serialize(mac)

      assert {:error, {:unknown_caveat, "unknown_thing"}} = Macaroon.verify(token)
    end

    test "rejects non-integer user_id" do
      mac =
        Macaroon.create("loomkin-local", "test-id", root_key())
        |> Macaroon.attenuate([
          "user_id = abc",
          "workspace_id = ws-1",
          "role = owner",
          "expires = #{future_expiry()}"
        ])

      token = Macaroon.serialize(mac)

      assert {:error, :invalid_user_id} = Macaroon.verify(token)
    end
  end

  # --- Helpers ---

  # NOTE: This duplicates the production root_key/0 derivation from
  # Loomkin.Relay.Macaroon. It is intentionally kept in sync so we can
  # construct macaroons with valid signatures for edge-case verification
  # tests (e.g. invalid role values that mint_daemon_token now rejects).
  defp root_key do
    base = Application.get_env(:loomkin, LoomkinWeb.Endpoint)[:secret_key_base]
    :crypto.mac(:hmac, :sha256, base, "loomkin:relay:macaroon:root-key-v1")
  end

  defp future_expiry do
    DateTime.utc_now()
    |> DateTime.add(3600, :second)
    |> DateTime.to_iso8601()
  end
end
