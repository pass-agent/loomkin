defmodule Loomkin.Channels.Telegram.WebhookTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Loomkin.Channels.Telegram.Webhook

  setup do
    try do
      Loomkin.Config.start_link()
    catch
      :error, {:already_started, _} -> :ok
    end

    :ok
  end

  describe "secret token verification" do
    test "rejects request with wrong secret token" do
      Loomkin.Config.put(:channels, %{
        telegram: %{
          enabled: true,
          secret_token: "correct-secret",
          allowed_chat_ids: [],
          allow_user_ids: []
        }
      })

      conn =
        conn(:post, "/", Jason.encode!(%{"message" => %{"chat" => %{"id" => 123}}}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-telegram-bot-api-secret-token", "wrong-secret")

      conn = Webhook.call(conn, Webhook.init([]))

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end

    test "rejects request with missing secret token header" do
      Loomkin.Config.put(:channels, %{
        telegram: %{
          enabled: true,
          secret_token: "correct-secret",
          allowed_chat_ids: [],
          allow_user_ids: []
        }
      })

      conn =
        conn(:post, "/", Jason.encode!(%{"message" => %{"chat" => %{"id" => 123}}}))
        |> put_req_header("content-type", "application/json")

      conn = Webhook.call(conn, Webhook.init([]))

      assert conn.status == 401
      assert conn.resp_body == "Unauthorized"
    end

    test "allows request with correct secret token" do
      Loomkin.Config.put(:channels, %{
        telegram: %{
          enabled: true,
          secret_token: "correct-secret",
          allowed_chat_ids: [],
          allow_user_ids: []
        }
      })

      conn =
        conn(
          :post,
          "/",
          Jason.encode!(%{
            "message" => %{"chat" => %{"id" => 123}, "text" => "hi", "from" => %{"id" => 1}}
          })
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-telegram-bot-api-secret-token", "correct-secret")

      conn = Webhook.call(conn, Webhook.init([]))

      assert conn.status == 200
    end

    test "skips verification when no secret token is configured" do
      Loomkin.Config.put(:channels, %{
        telegram: %{
          enabled: true,
          secret_token: nil,
          allowed_chat_ids: [],
          allow_user_ids: []
        }
      })

      conn =
        conn(
          :post,
          "/",
          Jason.encode!(%{
            "message" => %{"chat" => %{"id" => 123}, "text" => "hi", "from" => %{"id" => 1}}
          })
        )
        |> put_req_header("content-type", "application/json")

      conn = Webhook.call(conn, Webhook.init([]))

      assert conn.status == 200
    end

    test "skips verification when secret token is empty string" do
      Loomkin.Config.put(:channels, %{
        telegram: %{
          enabled: true,
          secret_token: "",
          allowed_chat_ids: [],
          allow_user_ids: []
        }
      })

      conn =
        conn(
          :post,
          "/",
          Jason.encode!(%{
            "message" => %{"chat" => %{"id" => 123}, "text" => "hi", "from" => %{"id" => 1}}
          })
        )
        |> put_req_header("content-type", "application/json")

      conn = Webhook.call(conn, Webhook.init([]))

      assert conn.status == 200
    end
  end
end
