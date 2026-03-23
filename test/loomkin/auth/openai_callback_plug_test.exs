defmodule Loomkin.Auth.OpenAICallbackPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Loomkin.Auth.OpenAICallbackPlug

  test "reads code and state from query params" do
    conn = conn(:get, "/auth/callback?code=test_code&state=test_state")
    conn = OpenAICallbackPlug.call(conn, OpenAICallbackPlug.init([]))

    assert conn.status == 400
    assert conn.resp_body =~ "invalid oauth state"
    refute conn.resp_body =~ "missing code or state"
  end
end
