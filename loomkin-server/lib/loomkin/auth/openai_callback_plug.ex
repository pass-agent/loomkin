defmodule Loomkin.Auth.OpenAICallbackPlug do
  @moduledoc false

  use Plug.Router

  alias Loomkin.Auth.OpenAICallbackServer
  alias Loomkin.Auth.OAuthServer

  plug :match
  plug :dispatch

  get "/auth/callback" do
    conn = Plug.Conn.fetch_query_params(conn)

    code = conn.query_params["code"]
    state = conn.query_params["state"]
    error = conn.query_params["error"]

    case {error, code, state} do
      {error, _code, _state} when is_binary(error) ->
        description = conn.query_params["error_description"] || error
        respond_html(conn, 400, error_html(description))

      {nil, code, state} when is_binary(code) and is_binary(state) ->
        case OAuthServer.handle_callback(state, code) do
          :ok ->
            conn = respond_html(conn, 200, success_html())
            :ok = OpenAICallbackServer.stop_async()
            conn

          {:error, :invalid_state} ->
            respond_html(conn, 400, error_html("invalid oauth state"))

          {:error, _reason} ->
            respond_html(conn, 500, error_html("token exchange failed"))
        end

      _ ->
        respond_html(conn, 400, error_html("missing code or state"))
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp respond_html(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  defp success_html do
    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <title>OpenAI Authorization Successful</title>
      </head>
      <body>
        <h1>Authorization successful</h1>
        <p>You can close this tab and return to Loomkin.</p>
      </body>
    </html>
    """
  end

  defp error_html(message) do
    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <title>OpenAI Authorization Failed</title>
      </head>
      <body>
        <h1>Authorization failed</h1>
        <p>#{message}</p>
      </body>
    </html>
    """
  end
end
