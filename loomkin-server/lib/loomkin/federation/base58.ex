defmodule Loomkin.Federation.Base58 do
  @moduledoc """
  Base58btc encoding/decoding for multibase-encoded keys.

  Uses the Bitcoin alphabet: `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`.
  This is the encoding used by the `z` multibase prefix in DID documents.
  """

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  @doc """
  Encode a binary to a Base58btc string.
  """
  @spec encode(binary()) :: String.t()
  def encode(<<>>), do: ""

  def encode(data) when is_binary(data) do
    # Count leading zero bytes (they map to '1' characters)
    leading_zeros = count_leading_zeros(data, 0)

    # Convert binary to integer and encode
    int_value = :binary.decode_unsigned(data, :big)

    encoded =
      if int_value == 0 do
        ""
      else
        int_value |> encode_int([]) |> to_string()
      end

    # Prepend '1' for each leading zero byte
    String.duplicate("1", leading_zeros) <> encoded
  end

  @doc """
  Decode a Base58btc string to a binary.

  Returns `{:ok, binary}` on success or `{:error, :invalid_base58_character}` if
  the input contains characters outside the Base58btc alphabet.
  """
  @spec decode(String.t()) :: {:ok, binary()} | {:error, :invalid_base58_character}
  def decode(""), do: {:ok, <<>>}

  def decode(string) when is_binary(string) do
    chars = String.to_charlist(string)

    # Count leading '1' characters (they map to zero bytes)
    leading_ones = count_leading_ones(chars, 0)

    # Decode only the non-leading-one characters to integer
    with {:ok, value} <- decode_chars(Enum.drop(chars, leading_ones)) do
      # Convert integer to binary
      decoded =
        if value == 0 do
          <<>>
        else
          :binary.encode_unsigned(value, :big)
        end

      # Prepend zero bytes for leading '1' characters
      {:ok, :binary.copy(<<0>>, leading_ones) <> decoded}
    end
  end

  defp encode_int(0, []), do: [Enum.at(@alphabet, 0)]
  defp encode_int(0, acc), do: acc

  defp encode_int(n, acc) do
    encode_int(div(n, 58), [Enum.at(@alphabet, rem(n, 58)) | acc])
  end

  defp count_leading_zeros(<<0, rest::binary>>, count), do: count_leading_zeros(rest, count + 1)
  defp count_leading_zeros(_, count), do: count

  defp count_leading_ones([?1 | rest], count), do: count_leading_ones(rest, count + 1)
  defp count_leading_ones(_, count), do: count

  defp decode_chars(chars) do
    Enum.reduce_while(chars, {:ok, 0}, fn char, {:ok, acc} ->
      case alphabet_index(char) do
        {:ok, index} -> {:cont, {:ok, acc * 58 + index}}
        :error -> {:halt, {:error, :invalid_base58_character}}
      end
    end)
  end

  defp alphabet_index(char) do
    case Enum.find_index(@alphabet, &(&1 == char)) do
      nil -> :error
      index -> {:ok, index}
    end
  end
end
