defmodule LoomkinWeb.SessionChannelOrchestrationTest do
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

  defp build_phase_signal(data) do
    %Jido.Signal{
      id: Ecto.UUID.generate(),
      source: "test",
      type: "session.orchestration.phase",
      datacontenttype: "application/json",
      time: DateTime.utc_now() |> DateTime.to_iso8601(),
      specversion: "1.0.2",
      data: data
    }
  end

  defp join_channel(user, scope) do
    {:ok, session} =
      Persistence.create_session(%{
        model: "anthropic:claude-sonnet-4-5",
        project_path: "/tmp",
        team_id: "team-orchestration",
        user_id: user.id
      })

    socket =
      socket(LoomkinWeb.UserSocket, "user_socket:#{user.id}", %{current_scope: scope})

    {:ok, _, socket} =
      subscribe_and_join(socket, SessionChannel, "session:#{session.id}")

    # Drain any spurious mailbox messages from join (e.g. email side-effects).
    receive do
      {:email, _email} -> :ok
    after
      0 -> :ok
    end

    {session, socket}
  end

  test "pushes orchestration_phase for signals matching the channel session_id", %{
    user: user,
    scope: scope
  } do
    {session, socket} = join_channel(user, scope)

    signal =
      build_phase_signal(%{
        session_id: session.id,
        subtype: :epic,
        epic_id: "abc",
        event: {:phase_entered, :plan_review}
      })

    send(socket.channel_pid, signal)

    assert_push(
      "orchestration_phase",
      %{
        subtype: :epic,
        event: {:phase_entered, :plan_review},
        epic_id: "abc"
      },
      1_000
    )
  end

  test "pushes orchestration_phase when session_id is nil (broadcast)", %{
    user: user,
    scope: scope
  } do
    {_session, socket} = join_channel(user, scope)

    signal =
      build_phase_signal(%{
        session_id: nil,
        subtype: :epic,
        epic_id: "abc",
        event: {:phase_entered, :plan_review}
      })

    send(socket.channel_pid, signal)

    assert_push(
      "orchestration_phase",
      %{
        subtype: :epic,
        event: {:phase_entered, :plan_review},
        epic_id: "abc"
      },
      1_000
    )
  end

  test "does NOT push orchestration_phase for a different session_id", %{
    user: user,
    scope: scope
  } do
    {_session, socket} = join_channel(user, scope)

    signal =
      build_phase_signal(%{
        session_id: Ecto.UUID.generate(),
        subtype: :epic,
        epic_id: "abc",
        event: {:phase_entered, :plan_review}
      })

    send(socket.channel_pid, signal)

    refute_push("orchestration_phase", _, 500)
  end
end
