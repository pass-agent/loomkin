defmodule LoomkinWeb.SessionChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  import Loomkin.AccountsFixtures

  alias Loomkin.Accounts.Scope
  alias Loomkin.Session.Persistence
  alias LoomkinWeb.SessionChannel

  @endpoint LoomkinWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Loomkin.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Loomkin.Repo, {:shared, self()})

    user = user_fixture()
    scope = Scope.for_user(user)

    {:ok, user: user, scope: scope}
  end

  test "forwards peer_message content from signal data message field", %{user: user, scope: scope} do
    {:ok, session} =
      Persistence.create_session(%{
        model: "anthropic:claude-sonnet-4-5",
        project_path: "/tmp",
        team_id: "team-123",
        user_id: user.id
      })

    socket = socket(LoomkinWeb.UserSocket, "user_socket:#{user.id}", %{current_scope: scope})

    {:ok, _, socket} =
      subscribe_and_join(socket, SessionChannel, "session:#{session.id}")

    receive do
      {:email, _email} -> :ok
    after
      0 -> :ok
    end

    signal =
      Loomkin.Signals.Collaboration.PeerMessage.new!(%{
        from: "system",
        team_id: "team-123"
      })

    signal = %{
      signal
      | data:
          Map.merge(signal.data, %{
            target: "concierge",
            message: {:peer_message, "system", "spawned researcher"}
          })
    }

    send(socket.channel_pid, signal)

    assert_push "peer_message", %{
      from: "system",
      to: "concierge",
      content: "spawned researcher",
      team_id: "team-123"
    }
  end

  test "formats max-iteration agent errors for cli consumers", %{user: user, scope: scope} do
    {:ok, session} =
      Persistence.create_session(%{
        model: "anthropic:claude-sonnet-4-5",
        project_path: "/tmp",
        team_id: "team-123",
        user_id: user.id
      })

    socket = socket(LoomkinWeb.UserSocket, "user_socket:#{user.id}", %{current_scope: scope})

    {:ok, _, socket} =
      subscribe_and_join(socket, SessionChannel, "session:#{session.id}")

    receive do
      {:email, _email} -> :ok
    after
      0 -> :ok
    end

    signal =
      Loomkin.Signals.Agent.Error.new!(%{
        agent_name: "concierge",
        team_id: "team-123"
      })

    signal = %{
      signal
      | data:
          Map.merge(signal.data, %{
            payload: %{iterations: 30, max: 30}
          })
    }

    send(socket.channel_pid, signal)

    assert_push "agent_error", %{
      agent_name: "concierge",
      error: "Exceeded max iterations (30)"
    }
  end
end
