defmodule Loomkin.Federation.IdentityTest do
  use ExUnit.Case, async: false

  alias Loomkin.Federation.Identity

  @tmp_dir "tmp/test_keys_#{System.unique_integer([:positive])}"

  setup do
    File.rm_rf!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "generate_keypair/0" do
    test "produces valid Ed25519 key pair" do
      keypair = Identity.generate_keypair()

      assert is_binary(keypair.public)
      assert is_binary(keypair.private)
      assert byte_size(keypair.public) == 32
      assert byte_size(keypair.private) == 32
    end

    test "produces different keypairs on each call" do
      kp1 = Identity.generate_keypair()
      kp2 = Identity.generate_keypair()

      refute kp1.public == kp2.public
      refute kp1.private == kp2.private
    end
  end

  describe "sign/2 and verify/3" do
    setup do
      keypair = Identity.generate_keypair()
      %{keypair: keypair}
    end

    test "roundtrip succeeds for arbitrary data", %{keypair: kp} do
      payload = "hello, federation!"
      signature = Identity.sign(payload, kp.private)

      assert is_binary(signature)
      assert byte_size(signature) == 64
      assert Identity.verify(payload, signature, kp.public)
    end

    test "verify fails with tampered data", %{keypair: kp} do
      payload = "original message"
      signature = Identity.sign(payload, kp.private)

      refute Identity.verify("tampered message", signature, kp.public)
    end

    test "verify fails with wrong public key", %{keypair: kp} do
      other_kp = Identity.generate_keypair()
      payload = "test payload"
      signature = Identity.sign(payload, kp.private)

      refute Identity.verify(payload, signature, other_kp.public)
    end

    test "sign works with empty binary", %{keypair: kp} do
      signature = Identity.sign("", kp.private)
      assert Identity.verify("", signature, kp.public)
    end

    test "sign works with binary data", %{keypair: kp} do
      data = :crypto.strong_rand_bytes(256)
      signature = Identity.sign(data, kp.private)
      assert Identity.verify(data, signature, kp.public)
    end
  end

  describe "sign_record/2 and verify_record/3" do
    setup do
      keypair = Identity.generate_keypair()
      %{keypair: keypair}
    end

    test "roundtrip with map record", %{keypair: kp} do
      record = %{"type" => "skill", "name" => "debug-detective", "version" => 1}
      {encoded, signature} = Identity.sign_record(record, kp.private)

      assert is_binary(encoded)
      assert is_binary(signature)

      # Verify using the encoded binary
      assert Identity.verify_record(encoded, signature, kp.public)

      # Verify using the original map (re-encodes it)
      assert Identity.verify_record(record, signature, kp.public)
    end

    test "verify_record fails with tampered record", %{keypair: kp} do
      record = %{"type" => "skill", "name" => "debug-detective"}
      {_encoded, signature} = Identity.sign_record(record, kp.private)

      tampered = %{"type" => "skill", "name" => "evil-skill"}
      refute Identity.verify_record(tampered, signature, kp.public)
    end
  end

  describe "get_or_create_keypair/0" do
    test "generates and persists keypair on first call" do
      # Override the config to use our test-specific directory
      original = Application.get_env(:loomkin, Identity, [])
      Application.put_env(:loomkin, Identity, Keyword.put(original, :key_path, @tmp_dir))

      on_exit(fn -> Application.put_env(:loomkin, Identity, original) end)

      refute File.exists?(Path.join(@tmp_dir, "identity.pub"))

      assert {:ok, keypair} = Identity.get_or_create_keypair()
      assert byte_size(keypair.public) == 32
      assert byte_size(keypair.private) == 32

      # Files should now exist
      assert File.exists?(Path.join(@tmp_dir, "identity.pub"))
      assert File.exists?(Path.join(@tmp_dir, "identity.key"))
    end

    test "loads existing keypair on subsequent calls" do
      original = Application.get_env(:loomkin, Identity, [])
      Application.put_env(:loomkin, Identity, Keyword.put(original, :key_path, @tmp_dir))

      on_exit(fn -> Application.put_env(:loomkin, Identity, original) end)

      assert {:ok, first} = Identity.get_or_create_keypair()
      assert {:ok, second} = Identity.get_or_create_keypair()

      assert first.public == second.public
      assert first.private == second.private
    end
  end

  describe "multibase encoding" do
    test "encode_multibase produces z-prefixed string" do
      keypair = Identity.generate_keypair()
      encoded = Identity.encode_multibase(keypair.public)

      assert String.starts_with?(encoded, "z")
      assert String.length(encoded) > 1
    end

    test "roundtrip encode/decode preserves public key" do
      keypair = Identity.generate_keypair()
      encoded = Identity.encode_multibase(keypair.public)

      assert {:ok, decoded} = Identity.decode_multibase(encoded)
      assert decoded == keypair.public
    end

    test "decode_multibase rejects invalid prefix" do
      assert {:error, :invalid_multibase_prefix} = Identity.decode_multibase("Q" <> "abc")
    end

    test "decode_multibase rejects truncated key (too short)" do
      # Create a valid multicodec prefix with only 16 bytes instead of 32
      truncated = <<0xED, 0x01>> <> :crypto.strong_rand_bytes(16)
      encoded = "z" <> Loomkin.Federation.Base58.encode(truncated)

      assert {:error, :invalid_key_length} = Identity.decode_multibase(encoded)
    end

    test "decode_multibase rejects oversized key (too long)" do
      # Create a valid multicodec prefix with 48 bytes instead of 32
      oversized = <<0xED, 0x01>> <> :crypto.strong_rand_bytes(48)
      encoded = "z" <> Loomkin.Federation.Base58.encode(oversized)

      assert {:error, :invalid_key_length} = Identity.decode_multibase(encoded)
    end
  end
end
