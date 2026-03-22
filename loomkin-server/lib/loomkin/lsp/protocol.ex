defmodule Loomkin.LSP.Protocol do
  @moduledoc """
  LSP JSON-RPC 2.0 message encoding and decoding.

  Handles Content-Length framed messages per the Language Server Protocol spec.
  """

  @doc "Encode a JSON-RPC request message with Content-Length header."
  @spec encode_request(integer(), String.t(), map()) :: iodata()
  def encode_request(id, method, params \\ %{}) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    encode_message(body)
  end

  @doc "Encode a JSON-RPC notification (no id)."
  @spec encode_notification(String.t(), map()) :: iodata()
  def encode_notification(method, params \\ %{}) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params
      })

    encode_message(body)
  end

  @doc "Decode a complete JSON-RPC message body (already extracted from Content-Length frame)."
  @spec decode_message(binary()) :: {:ok, map()} | {:error, term()}
  def decode_message(body) do
    case Jason.decode(body) do
      {:ok, %{"jsonrpc" => "2.0"} = msg} ->
        {:ok, classify_message(msg)}

      {:ok, _} ->
        {:error, :invalid_jsonrpc}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  @doc """
  Extract one complete message from a binary buffer.

  Returns `{:ok, message_map, remaining_buffer}` or `{:incomplete, buffer}`.
  """
  @spec extract_message(binary()) :: {:ok, map(), binary()} | {:incomplete, binary()}
  def extract_message(buffer) do
    case parse_header(buffer) do
      {:ok, content_length, rest} ->
        if byte_size(rest) >= content_length do
          <<body::binary-size(^content_length), remaining::binary>> = rest

          case decode_message(body) do
            {:ok, msg} -> {:ok, msg, remaining}
            {:error, _} = err -> err
          end
        else
          {:incomplete, buffer}
        end

      :incomplete ->
        {:incomplete, buffer}
    end
  end

  @doc "Build an initialize request params map."
  @spec initialize_params(String.t(), String.t()) :: map()
  def initialize_params(root_uri, client_name \\ "loom") do
    %{
      "processId" => System.pid() |> String.to_integer(),
      "clientInfo" => %{"name" => client_name, "version" => "0.1.0"},
      "rootUri" => root_uri,
      "capabilities" => %{
        "textDocument" => %{
          "publishDiagnostics" => %{
            "relatedInformation" => true,
            "tagSupport" => %{"valueSet" => [1, 2]}
          },
          "synchronization" => %{
            "didOpen" => true,
            "didClose" => true
          }
        }
      }
    }
  end

  @doc "Build textDocument/didOpen notification params."
  @spec did_open_params(String.t(), String.t(), String.t(), integer()) :: map()
  def did_open_params(uri, language_id, text, version \\ 1) do
    %{
      "textDocument" => %{
        "uri" => uri,
        "languageId" => language_id,
        "version" => version,
        "text" => text
      }
    }
  end

  @doc "Build textDocument/didClose notification params."
  @spec did_close_params(String.t()) :: map()
  def did_close_params(uri) do
    %{"textDocument" => %{"uri" => uri}}
  end

  @doc "Convert a file path to a file:// URI."
  @spec path_to_uri(String.t()) :: String.t()
  def path_to_uri(path) do
    "file://" <> Path.expand(path)
  end

  @doc "Convert a file:// URI back to a file path."
  @spec uri_to_path(String.t()) :: String.t()
  def uri_to_path("file://" <> path), do: path
  def uri_to_path(path), do: path

  @doc "Map LSP diagnostic severity integer to atom."
  @spec severity_name(integer()) :: atom()
  def severity_name(1), do: :error
  def severity_name(2), do: :warning
  def severity_name(3), do: :information
  def severity_name(4), do: :hint
  def severity_name(_), do: :unknown

  @doc "Map severity atom to LSP integer."
  @spec severity_value(atom()) :: integer()
  def severity_value(:error), do: 1
  def severity_value(:warning), do: 2
  def severity_value(:information), do: 3
  def severity_value(:hint), do: 4
  def severity_value(_), do: 0

  # --- Private ---

  defp encode_message(body) do
    length = byte_size(body)
    "Content-Length: #{length}\r\n\r\n#{body}"
  end

  defp parse_header(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {pos, 4} ->
        header = binary_part(buffer, 0, pos)
        rest = binary_part(buffer, pos + 4, byte_size(buffer) - pos - 4)

        case Regex.run(~r/Content-Length:\s*(\d+)/i, header) do
          [_, length_str] ->
            {:ok, String.to_integer(length_str), rest}

          nil ->
            :incomplete
        end

      :nomatch ->
        :incomplete
    end
  end

  defp classify_message(%{"id" => _id, "method" => _method} = msg) do
    Map.put(msg, :type, :request)
  end

  defp classify_message(%{"id" => _id, "result" => _result} = msg) do
    Map.put(msg, :type, :response)
  end

  defp classify_message(%{"id" => _id, "error" => _error} = msg) do
    Map.put(msg, :type, :error_response)
  end

  defp classify_message(%{"method" => _method} = msg) do
    Map.put(msg, :type, :notification)
  end

  defp classify_message(msg) do
    Map.put(msg, :type, :unknown)
  end
end
