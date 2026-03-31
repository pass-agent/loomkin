defmodule Loomkin.Relay.Server.SocketTest do
  use Loomkin.DataCase, async: false

  import Phoenix.ChannelTest
  import Ecto.Query, only: []

  alias Loomkin.Relay.Macaroon
  alias Loomkin.Relay.Server.Socket

  @endpoint LoomkinWeb.Endpoint

  @workspace_id "ws-socket-test"

  setup do
    user = Loomkin.AccountsFixtures.user_fixture()
    {:ok, user: user}
  end

  describe "connect/3" do
    test "rejects connection with no params" do
      assert :error = connect(Socket, %{})
    end

    test "rejects connection with empty token" do
      assert :error = connect(Socket, %{"token" => ""})
    end

    test "rejects connection with invalid token" do
      assert :error = connect(Socket, %{"token" => "not-a-valid-macaroon"})
    end

    test "rejects connection with expired token", %{user: user} do
      token = Macaroon.mint_daemon_token(user.id, @workspace_id, ttl: -1)
      assert :error = connect(Socket, %{"token" => token})
    end

    test "rejects connection with tampered token", %{user: user} do
      token = Macaroon.mint_daemon_token(user.id, @workspace_id)
      {:ok, mac} = Macaroon.deserialize(token)
      tampered = %{mac | signature: :crypto.strong_rand_bytes(32)}
      tampered_token = Macaroon.serialize(tampered)

      assert :error = connect(Socket, %{"token" => tampered_token})
    end

    test "accepts valid owner token", %{user: user} do
      token = Macaroon.mint_daemon_token(user.id, @workspace_id, role: "owner")
      assert {:ok, socket} = connect(Socket, %{"token" => token})

      assert socket.assigns.user_id == user.id
      assert socket.assigns.workspace_id == @workspace_id
      assert socket.assigns.role == "owner"
    end

    test "accepts valid collaborator token", %{user: user} do
      token = Macaroon.mint_daemon_token(user.id, @workspace_id, role: "collaborator")
      assert {:ok, socket} = connect(Socket, %{"token" => token})

      assert socket.assigns.role == "collaborator"
    end

    test "accepts valid observer token", %{user: user} do
      token = Macaroon.mint_daemon_token(user.id, @workspace_id, role: "observer")
      assert {:ok, socket} = connect(Socket, %{"token" => token})

      assert socket.assigns.role == "observer"
    end

    test "parses integer user_id from claims", %{user: user} do
      token = Macaroon.mint_daemon_token(user.id, @workspace_id)
      assert {:ok, socket} = connect(Socket, %{"token" => token})

      assert is_integer(socket.assigns.user_id)
      assert socket.assigns.user_id == user.id
    end
  end

  describe "id/1" do
    test "returns socket id based on user_id", %{user: user} do
      token = Macaroon.mint_daemon_token(user.id, @workspace_id)
      assert {:ok, socket} = connect(Socket, %{"token" => token})

      assert socket.id == "daemon_socket:#{user.id}"
    end
  end
end
