defmodule Loomkin.Channels.Telegram.PollerTest do
  use ExUnit.Case, async: false

  import Mox

  alias Loomkin.Channels.Telegram.Poller

  setup :verify_on_exit!

  setup do
    # Set up Ecto sandbox in shared mode so the poller GenServer can access the DB
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Loomkin.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Loomkin.Repo, {:shared, self()})

    # Point the adapter at our Mox mock
    Application.put_env(:loomkin, :telegex_module, Loomkin.MockTelegex)
    Mox.set_mox_global()

    try do
      Loomkin.Config.start_link()
    catch
      :error, {:already_started, _} -> :ok
    end

    # Set up a permissive telegram config so ACL checks pass
    Loomkin.Config.put(:channels, %{
      telegram: %{
        enabled: true,
        mode: "polling",
        secret_token: nil,
        allowed_chat_ids: [],
        allow_user_ids: []
      }
    })

    on_exit(fn ->
      Application.delete_env(:loomkin, :telegex_module)
    end)

    :ok
  end

  describe "init/1" do
    test "starts with offset 0 and sends :poll" do
      # First poll returns empty list, then we stop
      expect(Loomkin.MockTelegex, :get_updates, fn opts ->
        assert Keyword.get(opts, :offset) == 0
        assert Keyword.get(opts, :timeout) == 30
        {:ok, []}
      end)

      # Second poll — we'll stop the process before it resolves
      stub(Loomkin.MockTelegex, :get_updates, fn _opts -> {:ok, []} end)

      {:ok, pid} = Poller.start_link()
      # Give it time to poll
      Process.sleep(100)

      GenServer.stop(pid, :normal, 1000)
    end
  end

  describe "polling loop" do
    test "dispatches updates through the router and advances offset" do
      test_pid = self()

      update = %{
        "update_id" => 100,
        "message" => %{
          "message_id" => 1,
          "text" => "hello",
          "chat" => %{"id" => 999},
          "from" => %{"id" => 42, "username" => "testuser"}
        }
      }

      # First poll: return one update
      expect(Loomkin.MockTelegex, :get_updates, fn opts ->
        assert Keyword.get(opts, :offset) == 0
        send(test_pid, {:polled, Keyword.get(opts, :offset)})
        {:ok, [update]}
      end)

      # Second poll: should have offset 101 (100 + 1)
      expect(Loomkin.MockTelegex, :get_updates, fn opts ->
        assert Keyword.get(opts, :offset) == 101
        send(test_pid, {:polled, Keyword.get(opts, :offset)})
        {:ok, []}
      end)

      # Further polls just return empty
      stub(Loomkin.MockTelegex, :get_updates, fn _opts -> {:ok, []} end)

      {:ok, pid} = Poller.start_link()

      assert_receive {:polled, 0}, 1000
      assert_receive {:polled, 101}, 1000

      GenServer.stop(pid, :normal, 1000)
    end

    test "handles empty update list without changing offset" do
      test_pid = self()

      # Return empty on first two polls
      expect(Loomkin.MockTelegex, :get_updates, 2, fn opts ->
        send(test_pid, {:polled, Keyword.get(opts, :offset)})
        {:ok, []}
      end)

      stub(Loomkin.MockTelegex, :get_updates, fn _opts -> {:ok, []} end)

      {:ok, pid} = Poller.start_link()

      # Both polls should have offset 0 since no updates were processed
      assert_receive {:polled, 0}, 1000
      assert_receive {:polled, 0}, 1000

      GenServer.stop(pid, :normal, 1000)
    end

    test "retries after error with delay" do
      test_pid = self()

      # First poll: error
      expect(Loomkin.MockTelegex, :get_updates, fn _opts ->
        send(test_pid, :error_poll)
        {:error, :network_error}
      end)

      # Second poll: success after retry
      expect(Loomkin.MockTelegex, :get_updates, fn _opts ->
        send(test_pid, :retry_poll)
        {:ok, []}
      end)

      stub(Loomkin.MockTelegex, :get_updates, fn _opts -> {:ok, []} end)

      {:ok, pid} = Poller.start_link()

      assert_receive :error_poll, 1000
      # Retry should come after the delay (~3s)
      assert_receive :retry_poll, 5000

      GenServer.stop(pid, :normal, 1000)
    end

    test "sends command responses back to chat" do
      test_pid = self()

      # Update with a /status command — no binding exists so will get a "no binding" response
      update = %{
        "update_id" => 200,
        "message" => %{
          "message_id" => 1,
          "text" => "/status",
          "chat" => %{"id" => 888},
          "from" => %{"id" => 42}
        }
      }

      expect(Loomkin.MockTelegex, :get_updates, fn _opts ->
        {:ok, [update]}
      end)

      # The router will return a command response string for /status
      # Since there's no binding, the response will mention "binding"
      expect(Loomkin.MockTelegex, :send_message, fn chat_id, text, _opts ->
        send(test_pid, {:sent, chat_id, text})
        {:ok, %{}}
      end)

      stub(Loomkin.MockTelegex, :get_updates, fn _opts -> {:ok, []} end)

      {:ok, pid} = Poller.start_link()

      assert_receive {:sent, "888", text}, 2000
      assert text =~ "bind"

      GenServer.stop(pid, :normal, 1000)
    end

    test "ignores updates without chat_id" do
      test_pid = self()

      # Update with no message/chat structure
      update = %{
        "update_id" => 300,
        "channel_post" => %{"text" => "channel msg"}
      }

      expect(Loomkin.MockTelegex, :get_updates, fn _opts ->
        send(test_pid, :polled)
        {:ok, [update]}
      end)

      stub(Loomkin.MockTelegex, :get_updates, fn _opts -> {:ok, []} end)

      {:ok, pid} = Poller.start_link()

      assert_receive :polled, 1000
      # No send_message should have been called — just verify no crash
      Process.sleep(100)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal, 1000)
    end

    test "processes multiple updates in sequence and takes last update_id" do
      test_pid = self()

      updates = [
        %{
          "update_id" => 10,
          "message" => %{
            "message_id" => 1,
            "text" => "first",
            "chat" => %{"id" => 111},
            "from" => %{"id" => 1}
          }
        },
        %{
          "update_id" => 12,
          "message" => %{
            "message_id" => 2,
            "text" => "second",
            "chat" => %{"id" => 222},
            "from" => %{"id" => 2}
          }
        }
      ]

      # First poll returns two updates
      expect(Loomkin.MockTelegex, :get_updates, fn _opts ->
        {:ok, updates}
      end)

      # Next poll should have offset 13 (12 + 1)
      expect(Loomkin.MockTelegex, :get_updates, fn opts ->
        send(test_pid, {:next_offset, Keyword.get(opts, :offset)})
        {:ok, []}
      end)

      stub(Loomkin.MockTelegex, :get_updates, fn _opts -> {:ok, []} end)

      {:ok, pid} = Poller.start_link()

      assert_receive {:next_offset, 13}, 2000

      GenServer.stop(pid, :normal, 1000)
    end
  end
end
