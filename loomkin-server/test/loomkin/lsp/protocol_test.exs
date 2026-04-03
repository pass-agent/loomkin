defmodule Loomkin.LSP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Loomkin.LSP.Protocol

  describe "encode_request/3" do
    test "encodes a JSON-RPC request with Content-Length header" do
      msg = Protocol.encode_request(1, "initialize", %{"rootUri" => "file:///tmp"})
      msg = IO.iodata_to_binary(msg)

      assert msg =~ "Content-Length:"
      assert msg =~ "\r\n\r\n"

      [header, body] = String.split(msg, "\r\n\r\n", parts: 2)
      assert header =~ "Content-Length: #{byte_size(body)}"

      decoded = Jason.decode!(body)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "initialize"
      assert decoded["params"]["rootUri"] == "file:///tmp"
    end

    test "encodes request with empty params" do
      msg = Protocol.encode_request(42, "shutdown") |> IO.iodata_to_binary()
      [_, body] = String.split(msg, "\r\n\r\n", parts: 2)
      decoded = Jason.decode!(body)
      assert decoded["id"] == 42
      assert decoded["method"] == "shutdown"
      assert decoded["params"] == %{}
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification without an id" do
      msg = Protocol.encode_notification("initialized", %{}) |> IO.iodata_to_binary()
      [_, body] = String.split(msg, "\r\n\r\n", parts: 2)
      decoded = Jason.decode!(body)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "initialized"
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "decode_message/1" do
    test "decodes a response message" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"capabilities" => %{}}})
      assert {:ok, msg} = Protocol.decode_message(body)
      assert msg[:type] == :response
      assert msg["id"] == 1
      assert msg["result"]["capabilities"] == %{}
    end

    test "decodes a request message" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "textDocument/completion",
          "params" => %{}
        })

      assert {:ok, msg} = Protocol.decode_message(body)
      assert msg[:type] == :request
      assert msg["method"] == "textDocument/completion"
    end

    test "decodes a notification message" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "textDocument/publishDiagnostics",
          "params" => %{"uri" => "file:///test.ex", "diagnostics" => []}
        })

      assert {:ok, msg} = Protocol.decode_message(body)
      assert msg[:type] == :notification
      assert msg["method"] == "textDocument/publishDiagnostics"
    end

    test "decodes an error response" do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "error" => %{"code" => -32600, "message" => "Invalid request"}
        })

      assert {:ok, msg} = Protocol.decode_message(body)
      assert msg[:type] == :error_response
      assert msg["error"]["code"] == -32600
    end

    test "rejects non-JSON-RPC messages" do
      body = Jason.encode!(%{"not" => "jsonrpc"})
      assert {:error, :invalid_jsonrpc} = Protocol.decode_message(body)
    end

    test "returns error for invalid JSON" do
      assert {:error, {:json_decode, _}} = Protocol.decode_message("not json")
    end
  end

  describe "extract_message/1" do
    test "extracts a complete message from buffer" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => nil})
      buffer = "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"

      assert {:ok, msg, ""} = Protocol.extract_message(buffer)
      assert msg[:type] == :response
    end

    test "extracts message and returns remaining buffer" do
      body1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => nil})
      body2 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => nil})

      buffer =
        "Content-Length: #{byte_size(body1)}\r\n\r\n#{body1}" <>
          "Content-Length: #{byte_size(body2)}\r\n\r\n#{body2}"

      assert {:ok, msg1, remaining} = Protocol.extract_message(buffer)
      assert msg1["id"] == 1

      assert {:ok, msg2, ""} = Protocol.extract_message(remaining)
      assert msg2["id"] == 2
    end

    test "returns incomplete for partial header" do
      assert {:incomplete, "Content-"} = Protocol.extract_message("Content-")
    end

    test "returns incomplete for partial body" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => nil})
      partial = binary_part(body, 0, 5)
      buffer = "Content-Length: #{byte_size(body)}\r\n\r\n#{partial}"

      assert {:incomplete, ^buffer} = Protocol.extract_message(buffer)
    end
  end

  describe "path_to_uri/1 and uri_to_path/1" do
    test "converts path to file:// URI" do
      assert Protocol.path_to_uri("/home/user/project/lib/app.ex") ==
               "file:///home/user/project/lib/app.ex"
    end

    test "converts file:// URI back to path" do
      assert Protocol.uri_to_path("file:///home/user/project/lib/app.ex") ==
               "/home/user/project/lib/app.ex"
    end

    test "passes through non-URI paths" do
      assert Protocol.uri_to_path("/some/path") == "/some/path"
    end
  end

  describe "severity helpers" do
    test "severity_name maps integers to atoms" do
      assert Protocol.severity_name(1) == :error
      assert Protocol.severity_name(2) == :warning
      assert Protocol.severity_name(3) == :information
      assert Protocol.severity_name(4) == :hint
      assert Protocol.severity_name(99) == :unknown
    end

    test "severity_value maps atoms to integers" do
      assert Protocol.severity_value(:error) == 1
      assert Protocol.severity_value(:warning) == 2
      assert Protocol.severity_value(:information) == 3
      assert Protocol.severity_value(:hint) == 4
      assert Protocol.severity_value(:other) == 0
    end
  end

  describe "initialize_params/2" do
    test "builds valid initialize params" do
      params = Protocol.initialize_params("file:///project")

      assert params["rootUri"] == "file:///project"
      assert params["clientInfo"]["name"] == "loom"
      assert is_integer(params["processId"])
      assert params["capabilities"]["textDocument"]["publishDiagnostics"]
    end
  end

  describe "did_open_params/4" do
    test "builds valid didOpen params" do
      params = Protocol.did_open_params("file:///test.ex", "elixir", "defmodule Test do\nend", 1)
      td = params["textDocument"]
      assert td["uri"] == "file:///test.ex"
      assert td["languageId"] == "elixir"
      assert td["text"] == "defmodule Test do\nend"
      assert td["version"] == 1
    end
  end

  describe "did_close_params/1" do
    test "builds valid didClose params" do
      params = Protocol.did_close_params("file:///test.ex")
      assert params["textDocument"]["uri"] == "file:///test.ex"
    end
  end
end
