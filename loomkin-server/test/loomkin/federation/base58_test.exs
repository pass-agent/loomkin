defmodule Loomkin.Federation.Base58Test do
  use ExUnit.Case, async: true

  alias Loomkin.Federation.Base58

  describe "encode/1 with known Bitcoin test vectors" do
    test "empty binary encodes to empty string" do
      assert Base58.encode(<<>>) == ""
    end

    test "single zero byte encodes to '1'" do
      assert Base58.encode(<<0>>) == "1"
    end

    test "multiple leading zero bytes encode to leading '1's" do
      assert Base58.encode(<<0, 0, 0>>) == "111"
    end

    test "known address vector: 'Hello World!'" do
      # "Hello World!" -> "2NEpo7TZRRrLZSi2U" (well-known Base58 test vector)
      assert Base58.encode("Hello World!") == "2NEpo7TZRRrLZSi2U"
    end

    test "known vector: single byte 0x01" do
      assert Base58.encode(<<1>>) == "2"
    end

    test "known vector: 0x0000287fb4cd" do
      # Leading zero bytes preserved as '1's, rest encoded normally
      assert Base58.encode(<<0x00, 0x00, 0x28, 0x7F, 0xB4, 0xCD>>) == "11233QC4"
    end
  end

  describe "decode/1 with known Bitcoin test vectors" do
    test "empty string decodes to empty binary" do
      assert Base58.decode("") == {:ok, <<>>}
    end

    test "'1' decodes to single zero byte" do
      assert Base58.decode("1") == {:ok, <<0>>}
    end

    test "multiple '1's decode to leading zero bytes" do
      assert Base58.decode("111") == {:ok, <<0, 0, 0>>}
    end

    test "known address vector: '2NEpo7TZRRrLZSi2U' decodes to 'Hello World!'" do
      assert Base58.decode("2NEpo7TZRRrLZSi2U") == {:ok, "Hello World!"}
    end

    test "known vector: '11233QC4' decodes correctly" do
      assert Base58.decode("11233QC4") == {:ok, <<0x00, 0x00, 0x28, 0x7F, 0xB4, 0xCD>>}
    end

    test "rejects invalid characters" do
      assert Base58.decode("0OIl") == {:error, :invalid_base58_character}
    end
  end

  describe "roundtrip encode/decode" do
    test "random binary roundtrips" do
      data = :crypto.strong_rand_bytes(32)
      encoded = Base58.encode(data)
      assert {:ok, ^data} = Base58.decode(encoded)
    end

    test "binary with leading zeros roundtrips" do
      data = <<0, 0, 0>> <> :crypto.strong_rand_bytes(16)
      encoded = Base58.encode(data)
      assert {:ok, ^data} = Base58.decode(encoded)
    end
  end
end
