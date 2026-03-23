defmodule Loomkin.Auth.OpenAICallbackServerTest do
  use ExUnit.Case, async: false

  alias Loomkin.Auth.OpenAICallbackServer

  @test_port 14_556

  setup do
    Application.put_env(:loomkin, :openai_callback_idle_timeout_ms, 100)
    Application.put_env(:loomkin, :openai_callback_port, @test_port)
    OpenAICallbackServer.stop()

    on_exit(fn ->
      OpenAICallbackServer.stop()
      Application.delete_env(:loomkin, :openai_callback_idle_timeout_ms)
      Application.delete_env(:loomkin, :openai_callback_port)
    end)

    :ok
  end

  test "stop/0 closes the callback listener" do
    assert :ok = OpenAICallbackServer.ensure_started()

    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false], 1_000)

    :gen_tcp.close(socket)

    assert :ok = OpenAICallbackServer.stop()

    Process.sleep(50)

    assert {:error, _reason} =
             :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false], 500)
  end

  test "server auto-shuts down after idle timeout" do
    assert :ok = OpenAICallbackServer.ensure_started()

    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false], 1_000)

    :gen_tcp.close(socket)

    Process.sleep(250)

    assert {:error, _reason} =
             :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false], 500)
  end
end
