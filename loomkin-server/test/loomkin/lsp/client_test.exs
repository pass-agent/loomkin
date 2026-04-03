defmodule Loomkin.LSP.ClientTest do
  use ExUnit.Case, async: false

  alias Loomkin.LSP.Client
  alias Loomkin.LSP.Protocol

  @moduletag :tmp_dir

  # We test the client using a mock LSP server script that echoes responses.
  # This avoids needing a real language server installed.

  setup %{tmp_dir: tmp_dir} do
    # The LSP Registry is already started by Loomkin.LSP.Supervisor in the application.

    # Create a mock LSP server script
    mock_server_path = Path.join(tmp_dir, "mock_lsp.sh")

    File.write!(mock_server_path, """
    #!/bin/bash
    # Mock LSP server: reads JSON-RPC requests and responds with canned responses
    while IFS= read -r line; do
      # Read until we get Content-Length header
      if [[ "$line" == Content-Length:* ]]; then
        length=$(echo "$line" | tr -d '\\r' | cut -d' ' -f2)
        # Read blank line
        read -r blank
        # Read body
        body=""
        for ((i=0; i<length; i++)); do
          IFS= read -r -n 1 char
          body="${body}${char}"
        done

        # Parse the method from JSON
        method=$(echo "$body" | grep -o '"method":"[^"]*"' | cut -d'"' -f4)
        id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)

        if [ "$method" = "initialize" ]; then
          response='{"jsonrpc":"2.0","id":'$id',"result":{"capabilities":{"textDocumentSync":1,"diagnosticProvider":{}}}}'
          echo -ne "Content-Length: ${#response}\\r\\n\\r\\n${response}"
        elif [ "$method" = "shutdown" ]; then
          response='{"jsonrpc":"2.0","id":'$id',"result":null}'
          echo -ne "Content-Length: ${#response}\\r\\n\\r\\n${response}"
        elif [ "$method" = "textDocument/didOpen" ]; then
          # Send a diagnostic notification
          uri=$(echo "$body" | grep -o '"uri":"[^"]*"' | head -1 | cut -d'"' -f4)
          diag_params='{"uri":"'$uri'","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"severity":2,"message":"test warning","source":"mock"}]}'
          echo -ne "Content-Length: ${#diag_params}\\r\\n\\r\\n"
          notification='{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":'$diag_params'}'
          echo -ne "Content-Length: ${#notification}\\r\\n\\r\\n${notification}"
        fi
      fi
    done
    """)

    File.chmod!(mock_server_path, 0o755)

    %{tmp_dir: tmp_dir, mock_server: mock_server_path}
  end

  describe "client lifecycle" do
    test "starts and reports idle status", %{tmp_dir: _tmp_dir, mock_server: mock_server} do
      name = "test-lsp-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          name: name,
          command: mock_server,
          args: []
        )

      assert Client.status(name) == :idle
    end

    test "status returns :not_running for non-existent client" do
      assert Client.status("nonexistent-#{:erlang.unique_integer([:positive])}") == :not_running
    end
  end

  describe "protocol encoding roundtrip" do
    test "request encodes and decodes correctly" do
      msg = Protocol.encode_request(1, "initialize", %{"rootUri" => "file:///tmp"})
      binary = IO.iodata_to_binary(msg)

      assert {:ok, decoded, ""} = Protocol.extract_message(binary)
      assert decoded["id"] == 1
      assert decoded["method"] == "initialize"
    end

    test "notification encodes and decodes correctly" do
      msg = Protocol.encode_notification("initialized", %{})
      binary = IO.iodata_to_binary(msg)

      assert {:ok, decoded, ""} = Protocol.extract_message(binary)
      assert decoded["method"] == "initialized"
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "diagnostics storage" do
    test "get_diagnostics returns empty list for unknown file", %{mock_server: mock_server} do
      name = "test-diag-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          name: name,
          command: mock_server,
          args: []
        )

      assert {:ok, []} = Client.get_diagnostics(name, "/nonexistent/file.ex")
    end

    test "all_diagnostics returns empty map initially", %{mock_server: mock_server} do
      name = "test-alldiag-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          name: name,
          command: mock_server,
          args: []
        )

      assert {:ok, %{}} = Client.all_diagnostics(name)
    end
  end
end
