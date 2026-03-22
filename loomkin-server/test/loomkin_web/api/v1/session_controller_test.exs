defmodule LoomkinWeb.API.V1.SessionControllerTest do
  use Loomkin.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Loomkin.Session.Persistence

  @endpoint LoomkinWeb.Endpoint

  setup do
    user = Loomkin.AccountsFixtures.user_fixture()
    token = Loomkin.Accounts.generate_user_session_token(user)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, user: user, token: token}
  end

  defp create_test_session(user, attrs \\ %{}) do
    defaults = %{
      model: "claude-sonnet-4-20250514",
      project_path: "/home/user/project",
      title: "Test session",
      user_id: user.id
    }

    {:ok, session} = Persistence.create_session(Map.merge(defaults, attrs))
    session
  end

  defp create_test_message(session, attrs) do
    defaults = %{
      session_id: session.id,
      role: :user,
      content: "Hello"
    }

    {:ok, message} = Persistence.save_message(Map.merge(defaults, attrs))
    message
  end

  describe "GET /api/v1/sessions/:id (show)" do
    test "returns session JSON for the session owner", %{conn: conn, user: user} do
      session = create_test_session(user)

      conn = get(conn, "/api/v1/sessions/#{session.id}")
      resp = json_response(conn, 200)

      assert resp["ok"] == true
      assert resp["data"]["session"]["id"] == session.id
      assert resp["data"]["session"]["title"] == "Test session"
      assert resp["data"]["session"]["model"] == "claude-sonnet-4-20250514"
      assert resp["data"]["session"]["status"] == "active"
    end

    test "returns 404 for another user's session", %{conn: conn} do
      other_user = Loomkin.AccountsFixtures.user_fixture()
      session = create_test_session(other_user)

      conn = get(conn, "/api/v1/sessions/#{session.id}")
      resp = json_response(conn, 404)

      assert resp["ok"] == false
      assert resp["error"] == "session not found"
    end

    test "returns 404 for nonexistent session", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      conn = get(conn, "/api/v1/sessions/#{fake_id}")
      resp = json_response(conn, 404)

      assert resp["ok"] == false
    end
  end

  describe "GET /api/v1/sessions/:id/messages" do
    test "returns paginated messages", %{conn: conn, user: user} do
      session = create_test_session(user)
      create_test_message(session, %{role: :user, content: "Hello"})
      create_test_message(session, %{role: :assistant, content: "Hi there"})
      create_test_message(session, %{role: :user, content: "How are you?"})

      conn = get(conn, "/api/v1/sessions/#{session.id}/messages")
      resp = json_response(conn, 200)

      assert resp["ok"] == true
      assert resp["data"]["total"] == 3
      assert resp["data"]["offset"] == 0
      assert resp["data"]["limit"] == 50
      assert length(resp["data"]["messages"]) == 3

      [msg1, msg2, msg3] = resp["data"]["messages"]
      assert msg1["role"] == "user"
      assert msg1["content"] == "Hello"
      assert msg2["role"] == "assistant"
      assert msg2["content"] == "Hi there"
      assert msg3["role"] == "user"
      assert msg3["content"] == "How are you?"
    end

    test "respects offset and limit params", %{conn: conn, user: user} do
      session = create_test_session(user)

      for i <- 1..5 do
        create_test_message(session, %{role: :user, content: "Message #{i}"})
      end

      conn = get(conn, "/api/v1/sessions/#{session.id}/messages?offset=1&limit=2")
      resp = json_response(conn, 200)

      assert resp["data"]["total"] == 5
      assert resp["data"]["offset"] == 1
      assert resp["data"]["limit"] == 2
      assert length(resp["data"]["messages"]) == 2
      assert hd(resp["data"]["messages"])["content"] == "Message 2"
    end

    test "returns 404 for another user's session", %{conn: conn} do
      other_user = Loomkin.AccountsFixtures.user_fixture()
      session = create_test_session(other_user)

      conn = get(conn, "/api/v1/sessions/#{session.id}/messages")
      resp = json_response(conn, 404)

      assert resp["ok"] == false
    end

    test "returns message fields including tool_calls", %{conn: conn, user: user} do
      session = create_test_session(user)

      create_test_message(session, %{
        role: :assistant,
        content: "Let me check that.",
        tool_calls: [%{"id" => "call-1", "type" => "function", "function" => %{"name" => "read"}}],
        token_count: 42
      })

      conn = get(conn, "/api/v1/sessions/#{session.id}/messages")
      resp = json_response(conn, 200)

      [msg] = resp["data"]["messages"]
      assert msg["role"] == "assistant"
      assert msg["token_count"] == 42
      assert is_list(msg["tool_calls"])
      assert hd(msg["tool_calls"])["id"] == "call-1"
    end
  end

  describe "authentication" do
    test "returns 401 without auth header" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> get("/api/v1/sessions/#{Ecto.UUID.generate()}")

      resp = json_response(conn, 401)
      assert resp["ok"] == false
      assert resp["error"] == "unauthorized"
    end

    test "returns 401 with invalid token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer invalid-token-here")
        |> put_req_header("content-type", "application/json")
        |> get("/api/v1/sessions/#{Ecto.UUID.generate()}")

      resp = json_response(conn, 401)
      assert resp["ok"] == false
      assert resp["error"] == "unauthorized"
    end

    test "returns 401 with malformed auth header" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Token something")
        |> put_req_header("content-type", "application/json")
        |> get("/api/v1/sessions/#{Ecto.UUID.generate()}")

      resp = json_response(conn, 401)
      assert resp["ok"] == false
    end
  end

  describe "POST /api/v1/sessions (create)" do
    test "returns 503 when daemon not connected", %{conn: conn} do
      conn = post(conn, "/api/v1/sessions", %{"workspace_id" => "ws-nonexistent"})
      resp = json_response(conn, 503)

      assert resp["ok"] == false
      assert resp["error"] == "daemon not connected"
    end

    test "returns 400 without workspace_id", %{conn: conn} do
      conn = post(conn, "/api/v1/sessions", %{})
      resp = json_response(conn, 400)

      assert resp["ok"] == false
      assert resp["error"] == "workspace_id required"
    end
  end

  describe "POST /api/v1/sessions/:id/messages (send_message)" do
    test "returns 400 without text param", %{conn: conn} do
      session_id = Ecto.UUID.generate()
      conn = post(conn, "/api/v1/sessions/#{session_id}/messages", %{})
      resp = json_response(conn, 400)

      assert resp["ok"] == false
      assert resp["error"] == "text required"
    end
  end
end
