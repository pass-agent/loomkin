defmodule Loomkin.Social do
  @moduledoc """
  The Social context — CRUD, discovery, and social actions for snippets.
  """

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Schemas.Favorite
  alias Loomkin.Schemas.Follow
  alias Loomkin.Schemas.Snippet
  alias Loomkin.Accounts.User

  # ---------------------------------------------------------------------------
  # Snippet CRUD
  # ---------------------------------------------------------------------------

  def create_snippet(user, attrs) do
    %Snippet{}
    |> Snippet.changeset(attrs)
    |> Ecto.Changeset.put_change(:user_id, user && user.id)
    |> Repo.insert()
  end

  def update_snippet(user, %Snippet{} = snippet, attrs) do
    if snippet.user_id != user.id do
      {:error, :unauthorized}
    else
      snippet
      |> Snippet.changeset(attrs)
      |> Ecto.Changeset.optimistic_lock(:version)
      |> Repo.update()
    end
  end

  def delete_snippet(user, %Snippet{} = snippet) do
    if snippet.user_id != user.id do
      {:error, :unauthorized}
    else
      Repo.delete(snippet)
    end
  end

  def get_snippet!(id) do
    Repo.get!(Snippet, id) |> Repo.preload(:user)
  end

  def get_snippet_by_slug(username, slug, viewer \\ nil) do
    snippet =
      from(s in Snippet,
        join: u in assoc(s, :user),
        where: u.username == ^username and s.slug == ^slug,
        preload: [:user]
      )
      |> Repo.one()

    case snippet do
      nil ->
        nil

      %Snippet{visibility: :public} ->
        snippet

      %Snippet{visibility: :unlisted} ->
        snippet

      %Snippet{visibility: :private, user_id: owner_id} ->
        if viewer && viewer.id == owner_id, do: snippet, else: nil
    end
  end

  # ---------------------------------------------------------------------------
  # Listing & Discovery
  # ---------------------------------------------------------------------------

  def list_user_snippets(user, opts \\ []) do
    type = Keyword.get(opts, :type)
    visibility = Keyword.get(opts, :visibility)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(s in Snippet, where: s.user_id == ^user.id, order_by: [desc: s.inserted_at])
    |> maybe_filter_type(type)
    |> maybe_filter_visibility(visibility)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def list_public_snippets(opts \\ []) do
    type = Keyword.get(opts, :type)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    sort = Keyword.get(opts, :sort, :recent)

    from(s in Snippet, where: s.visibility == :public, preload: [:user])
    |> maybe_filter_type(type)
    |> apply_sort(sort)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def search_snippets(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    escaped =
      query
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = "%#{escaped}%"

    from(s in Snippet,
      where:
        s.visibility == :public and
          (ilike(s.title, ^pattern) or
             ilike(s.description, ^pattern) or
             fragment(
               "EXISTS (SELECT 1 FROM unnest(?) AS tag WHERE tag ILIKE ?)",
               s.tags,
               ^pattern
             )),
      order_by: [desc: s.inserted_at],
      preload: [:user]
    )
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def trending_snippets(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    days = Keyword.get(opts, :days, 7)
    since = NaiveDateTime.add(NaiveDateTime.utc_now(), -days, :day)

    from(s in Snippet,
      where: s.visibility == :public and s.inserted_at >= ^since,
      order_by: [desc: s.favorite_count, desc: s.fork_count, desc: s.inserted_at],
      preload: [:user]
    )
    |> limit(^limit)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Social Actions
  # ---------------------------------------------------------------------------

  def fork_snippet(user, %Snippet{} = snippet) do
    unless snippet.visibility in [:public, :unlisted] or snippet.user_id == user.id do
      {:error, :unauthorized}
    else
      do_fork_snippet(user, snippet)
    end
  end

  defp do_fork_snippet(user, snippet) do
    attrs = %{
      title: snippet.title,
      description: snippet.description,
      type: snippet.type,
      visibility: :private,
      content: snippet.content,
      tags: snippet.tags,
      forked_from_id: snippet.id
    }

    Repo.transaction(fn ->
      with {:ok, fork} <- create_snippet(user, attrs) do
        {1, _} =
          from(s in Snippet, where: s.id == ^snippet.id)
          |> Repo.update_all(inc: [fork_count: 1])

        fork
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # End of do_fork_snippet — fork_snippet guard clause returns {:error, :unauthorized} above

  def toggle_favorite(user, %Snippet{} = snippet) do
    case Repo.get_by(Favorite, user_id: user.id, snippet_id: snippet.id) do
      nil ->
        changeset =
          %Favorite{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.put_change(:user_id, user.id)
          |> Ecto.Changeset.put_change(:snippet_id, snippet.id)
          |> Ecto.Changeset.unique_constraint([:user_id, :snippet_id])

        Repo.transaction(fn ->
          case Repo.insert(changeset) do
            {:ok, favorite} ->
              from(s in Snippet, where: s.id == ^snippet.id)
              |> Repo.update_all(inc: [favorite_count: 1])

              {:favorited, favorite}

            {:error, _changeset} ->
              # Lost race — another process inserted first, treat as no-op
              {:already_favorited, nil}
          end
        end)

      existing ->
        Repo.transaction(fn ->
          {:ok, _} = Repo.delete(existing)

          from(s in Snippet, where: s.id == ^snippet.id and s.favorite_count > 0)
          |> Repo.update_all(inc: [favorite_count: -1])

          :unfavorited
        end)
    end
  end

  def favorited?(user, %Snippet{} = snippet) do
    Repo.exists?(
      from(f in Favorite, where: f.user_id == ^user.id and f.snippet_id == ^snippet.id)
    )
  end

  @doc """
  Lists snippets the user has favorited, with the snippet preloaded.
  """
  def list_favorites(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(f in Favorite,
      where: f.user_id == ^user.id,
      join: s in assoc(f, :snippet),
      where: s.visibility in [:public, :unlisted] or s.user_id == ^user.id,
      preload: [snippet: {s, :user}],
      order_by: [desc: f.inserted_at]
    )
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns a map of snippet type => count for the given user.
  """
  def snippet_counts_by_type(user) do
    from(s in Snippet,
      where: s.user_id == ^user.id,
      group_by: s.type,
      select: {s.type, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
    |> then(fn counts ->
      %{
        skills: Map.get(counts, :skill, 0),
        prompts: Map.get(counts, :prompt, 0),
        kin_agents: Map.get(counts, :kin_agent, 0),
        chat_logs: Map.get(counts, :chat_log, 0)
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Follows
  # ---------------------------------------------------------------------------

  def follow(follower, followed) do
    %Follow{}
    |> Follow.changeset(%{})
    |> Ecto.Changeset.put_change(:follower_id, follower.id)
    |> Ecto.Changeset.put_change(:followed_id, followed.id)
    |> Follow.validate_not_self_follow()
    |> Repo.insert()
  end

  def unfollow(follower, followed) do
    case Repo.get_by(Follow, follower_id: follower.id, followed_id: followed.id) do
      nil -> {:error, :not_following}
      follow -> Repo.delete(follow)
    end
  end

  def following?(follower, followed) do
    Repo.exists?(
      from(f in Follow, where: f.follower_id == ^follower.id and f.followed_id == ^followed.id)
    )
  end

  def list_followers(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(f in Follow,
      where: f.followed_id == ^user.id,
      join: u in User,
      on: u.id == f.follower_id,
      select: u,
      order_by: [desc: f.inserted_at]
    )
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def list_following(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(f in Follow,
      where: f.follower_id == ^user.id,
      join: u in User,
      on: u.id == f.followed_id,
      select: u,
      order_by: [desc: f.inserted_at]
    )
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def follower_count(user) do
    Repo.aggregate(from(f in Follow, where: f.followed_id == ^user.id), :count)
  end

  def following_count(user) do
    Repo.aggregate(from(f in Follow, where: f.follower_id == ^user.id), :count)
  end

  def following_activity(user, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(s in Snippet,
      where: s.visibility == :public,
      join: f in Follow,
      on: f.followed_id == s.user_id,
      where: f.follower_id == ^user.id,
      order_by: [desc: s.inserted_at],
      preload: [:user]
    )
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns active sessions for a given user. Used by Presence to show
  what a followed user is currently working on.
  """
  def live_sessions_for_user(user) do
    from(s in Loomkin.Schemas.Session,
      where: s.user_id == ^user.id and s.status == :active,
      order_by: [desc: s.updated_at]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Chat Log Saving
  # ---------------------------------------------------------------------------

  @doc """
  Saves a session's messages as a chat_log snippet.

  Takes the session's messages and creates an immutable snapshot.
  """
  def save_chat_log(user, session, attrs \\ %{}) do
    if session.user_id && session.user_id != user.id do
      {:error, :unauthorized}
    else
      messages =
        from(m in Loomkin.Schemas.Message,
          where: m.session_id == ^session.id,
          order_by: [asc: m.inserted_at]
        )
        |> Repo.all()
        |> Enum.map(fn msg ->
          %{
            "role" => to_string(msg.role),
            "content" => msg.content
          }
        end)

      # Normalize attrs to support both atom and string keys
      title = attrs[:title] || attrs["title"] || session.title || "Chat Log"
      description = attrs[:description] || attrs["description"]
      tags = attrs[:tags] || attrs["tags"] || []
      visibility = attrs[:visibility] || attrs["visibility"] || :private
      agent_count = attrs[:agent_count] || attrs["agent_count"] || 1
      summary = attrs[:summary] || attrs["summary"] || ""

      content = %{
        "messages" => messages,
        "model" => session.model,
        "agent_count" => agent_count,
        "summary" => summary
      }

      create_snippet(user, %{
        title: title,
        description: description,
        type: :chat_log,
        content: content,
        tags: tags,
        visibility: visibility
      })
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [s], s.type == ^type)

  defp maybe_filter_visibility(query, nil), do: query
  defp maybe_filter_visibility(query, vis), do: where(query, [s], s.visibility == ^vis)

  defp apply_sort(query, :recent), do: order_by(query, [s], desc: s.inserted_at)
  defp apply_sort(query, :most_favorited), do: order_by(query, [s], desc: s.favorite_count)
  defp apply_sort(query, :most_forked), do: order_by(query, [s], desc: s.fork_count)
  defp apply_sort(query, _), do: order_by(query, [s], desc: s.inserted_at)
end
