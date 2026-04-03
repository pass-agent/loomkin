defmodule LoomkinWeb.Presence do
  @moduledoc """
  Tracks live user activity across the platform.

  Topics:
    - "presence:global" — all online users
    - "presence:user:<user_id>" — specific user's activity
  """

  use Phoenix.Presence,
    otp_app: :loomkin,
    pubsub_server: Loomkin.PubSub

  @global_topic "presence:global"

  def global_topic, do: @global_topic

  def user_topic(user_id), do: "presence:user:#{user_id}"

  @doc """
  Track a user as online with optional metadata (page, etc.).
  """
  def track_user(pid, user, meta \\ %{}) do
    track(
      pid,
      @global_topic,
      user.id,
      Map.merge(
        %{
          username: user.username,
          display_name: user.display_name,
          avatar_url: user.avatar_url,
          online_at: System.system_time(:second)
        },
        meta
      )
    )
  end

  @doc """
  Update the metadata for a tracked user (e.g., page change).
  """
  def update_user(pid, user_id, meta) do
    update(pid, @global_topic, user_id, fn existing ->
      Map.merge(existing, meta)
    end)
  end

  @doc """
  Returns a list of currently online users with their metadata.
  """
  def list_online_users do
    list(@global_topic)
    |> Enum.map(fn {user_id_str, %{metas: [meta | _]}} ->
      Map.put(meta, :user_id, String.to_integer(user_id_str))
    end)
  end

  @doc """
  Returns true if the given user is currently online.
  """
  def online?(user_id) do
    list(@global_topic)
    |> Map.has_key?(to_string(user_id))
  end
end
