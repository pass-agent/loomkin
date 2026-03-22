defmodule Loomkin.SocialTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Social
  alias Loomkin.Schemas.Snippet

  import Loomkin.AccountsFixtures

  defp create_user(_context) do
    user = user_fixture()
    %{user: user}
  end

  defp snippet_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "Test Snippet #{System.unique_integer([:positive])}",
        type: :skill,
        description: "A test snippet",
        content: %{"body" => "hello world"},
        tags: ["test", "elixir"],
        visibility: :private
      },
      overrides
    )
  end

  describe "create_snippet/2" do
    setup :create_user

    test "creates a snippet with valid attrs", %{user: user} do
      attrs = snippet_attrs()
      assert {:ok, %Snippet{} = snippet} = Social.create_snippet(user, attrs)
      assert snippet.title == attrs.title
      assert snippet.type == :skill
      assert snippet.visibility == :private
      assert snippet.user_id == user.id
      assert snippet.slug != nil
    end

    test "auto-generates slug from title", %{user: user} do
      attrs = snippet_attrs(%{title: "My Cool Skill"})
      assert {:ok, snippet} = Social.create_snippet(user, attrs)
      assert snippet.slug == "my-cool-skill"
    end

    test "returns error for missing required fields", %{user: user} do
      assert {:error, changeset} = Social.create_snippet(user, %{})
      assert %{title: ["can't be blank"], type: ["can't be blank"]} = errors_on(changeset)
    end

    test "allows all snippet types", %{user: user} do
      for type <- [:skill, :prompt, :kin_agent, :chat_log] do
        attrs = snippet_attrs(%{type: type})
        assert {:ok, snippet} = Social.create_snippet(user, attrs)
        assert snippet.type == type
      end
    end
  end

  describe "update_snippet/3" do
    setup :create_user

    test "updates snippet fields and bumps version", %{user: user} do
      {:ok, snippet} = Social.create_snippet(user, snippet_attrs())
      assert snippet.version == 1

      assert {:ok, updated} = Social.update_snippet(user, snippet, %{title: "Updated Title"})
      assert updated.title == "Updated Title"
      assert updated.version == 2
    end

    test "returns error when user does not own snippet", %{user: user} do
      {:ok, snippet} = Social.create_snippet(user, snippet_attrs())
      other_user = user_fixture()

      assert {:error, :unauthorized} =
               Social.update_snippet(other_user, snippet, %{title: "Hacked"})
    end
  end

  describe "delete_snippet/2" do
    setup :create_user

    test "deletes the snippet", %{user: user} do
      {:ok, snippet} = Social.create_snippet(user, snippet_attrs())
      assert {:ok, _} = Social.delete_snippet(user, snippet)
      assert_raise Ecto.NoResultsError, fn -> Social.get_snippet!(snippet.id) end
    end
  end

  describe "get_snippet!/1" do
    setup :create_user

    test "returns the snippet by id", %{user: user} do
      {:ok, snippet} = Social.create_snippet(user, snippet_attrs())
      found = Social.get_snippet!(snippet.id)
      assert found.id == snippet.id
    end
  end

  describe "get_snippet_by_slug/2" do
    setup :create_user

    test "returns snippet by username and slug", %{user: user} do
      # Need to set username on user first
      user
      |> Ecto.Changeset.change(%{username: "testuser"})
      |> Repo.update!()

      {:ok, snippet} = Social.create_snippet(user, snippet_attrs(%{title: "Slug Test"}))

      # Owner can see their own private snippet
      found = Social.get_snippet_by_slug("testuser", snippet.slug, user)
      assert found.id == snippet.id

      # Non-owner cannot see private snippet
      assert Social.get_snippet_by_slug("testuser", snippet.slug) == nil
    end

    test "returns nil for non-existent slug", %{user: _user} do
      assert Social.get_snippet_by_slug("nobody", "nope") == nil
    end
  end

  describe "list_user_snippets/2" do
    setup :create_user

    test "returns user's snippets", %{user: user} do
      {:ok, _} = Social.create_snippet(user, snippet_attrs(%{type: :skill}))
      {:ok, _} = Social.create_snippet(user, snippet_attrs(%{type: :prompt}))

      snippets = Social.list_user_snippets(user)
      assert length(snippets) == 2
    end

    test "filters by type", %{user: user} do
      {:ok, _} = Social.create_snippet(user, snippet_attrs(%{type: :skill}))
      {:ok, _} = Social.create_snippet(user, snippet_attrs(%{type: :prompt}))

      skills = Social.list_user_snippets(user, type: :skill)
      assert length(skills) == 1
      assert hd(skills).type == :skill
    end
  end

  describe "list_public_snippets/1" do
    setup :create_user

    test "returns only public snippets", %{user: user} do
      {:ok, _} = Social.create_snippet(user, snippet_attrs(%{visibility: :public}))
      {:ok, _} = Social.create_snippet(user, snippet_attrs(%{visibility: :private}))

      public = Social.list_public_snippets()
      assert length(public) == 1
      assert hd(public).visibility == :public
    end

    test "returns recent snippets", %{user: user} do
      {:ok, _s1} =
        Social.create_snippet(user, snippet_attrs(%{visibility: :public, title: "first"}))

      {:ok, _s2} =
        Social.create_snippet(user, snippet_attrs(%{visibility: :public, title: "second"}))

      results = Social.list_public_snippets()
      assert length(results) == 2
    end
  end

  describe "search_snippets/2" do
    setup :create_user

    test "finds snippets by title", %{user: user} do
      {:ok, _} =
        Social.create_snippet(
          user,
          snippet_attrs(%{title: "Elixir Expert", visibility: :public, tags: ["beam"]})
        )

      {:ok, _} =
        Social.create_snippet(
          user,
          snippet_attrs(%{title: "Python Helper", visibility: :public, tags: ["snake"]})
        )

      results = Social.search_snippets("Elixir")
      assert length(results) == 1
      assert hd(results).title == "Elixir Expert"
    end
  end

  describe "fork_snippet/2" do
    setup :create_user

    test "creates a copy and increments fork count", %{user: user} do
      {:ok, original} = Social.create_snippet(user, snippet_attrs(%{visibility: :public}))

      other_user = user_fixture()
      assert {:ok, fork} = Social.fork_snippet(other_user, original)

      assert fork.forked_from_id == original.id
      assert fork.user_id == other_user.id
      assert fork.visibility == :private
      assert fork.title == original.title

      updated_original = Social.get_snippet!(original.id)
      assert updated_original.fork_count == 1
    end
  end

  describe "toggle_favorite/2" do
    setup :create_user

    test "favorites and unfavorites a snippet", %{user: user} do
      {:ok, snippet} = Social.create_snippet(user, snippet_attrs(%{visibility: :public}))
      other_user = user_fixture()

      # Favorite
      assert {:ok, {:favorited, _fav}} = Social.toggle_favorite(other_user, snippet)
      assert Social.favorited?(other_user, snippet)

      updated = Social.get_snippet!(snippet.id)
      assert updated.favorite_count == 1

      # Unfavorite
      assert {:ok, :unfavorited} = Social.toggle_favorite(other_user, snippet)
      refute Social.favorited?(other_user, snippet)

      updated = Social.get_snippet!(snippet.id)
      assert updated.favorite_count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Follows
  # ---------------------------------------------------------------------------

  describe "follow/2" do
    setup :create_user

    test "creates a follow relationship", %{user: user} do
      other = user_fixture()
      assert {:ok, follow} = Social.follow(user, other)
      assert follow.follower_id == user.id
      assert follow.followed_id == other.id
    end

    test "prevents self-follow", %{user: user} do
      assert {:error, changeset} = Social.follow(user, user)
      assert %{followed_id: ["cannot follow yourself"]} = errors_on(changeset)
    end

    test "prevents duplicate follows", %{user: user} do
      other = user_fixture()
      assert {:ok, _} = Social.follow(user, other)
      assert {:error, changeset} = Social.follow(user, other)
      assert %{follower_id: [_]} = errors_on(changeset)
    end
  end

  describe "unfollow/2" do
    setup :create_user

    test "removes a follow relationship", %{user: user} do
      other = user_fixture()
      {:ok, _} = Social.follow(user, other)
      assert {:ok, _} = Social.unfollow(user, other)
      refute Social.following?(user, other)
    end

    test "returns error when not following", %{user: user} do
      other = user_fixture()
      assert {:error, :not_following} = Social.unfollow(user, other)
    end
  end

  describe "following?/2" do
    setup :create_user

    test "returns true when following, false otherwise", %{user: user} do
      other = user_fixture()
      refute Social.following?(user, other)

      {:ok, _} = Social.follow(user, other)
      assert Social.following?(user, other)

      # Asymmetric — other does not follow user
      refute Social.following?(other, user)
    end
  end

  describe "list_followers/2 and list_following/2" do
    setup :create_user

    test "returns followers and following lists", %{user: user} do
      u1 = user_fixture()
      u2 = user_fixture()

      Social.follow(u1, user)
      Social.follow(u2, user)
      Social.follow(user, u1)

      followers = Social.list_followers(user)
      assert length(followers) == 2
      assert Enum.all?(followers, &(&1.id in [u1.id, u2.id]))

      following = Social.list_following(user)
      assert length(following) == 1
      assert hd(following).id == u1.id
    end
  end

  describe "follower_count/1 and following_count/1" do
    setup :create_user

    test "returns correct counts", %{user: user} do
      u1 = user_fixture()
      u2 = user_fixture()

      assert Social.follower_count(user) == 0
      assert Social.following_count(user) == 0

      Social.follow(u1, user)
      Social.follow(u2, user)
      Social.follow(user, u1)

      assert Social.follower_count(user) == 2
      assert Social.following_count(user) == 1
    end
  end

  describe "following_activity/2" do
    setup :create_user

    test "returns public snippets from followed users", %{user: user} do
      author = user_fixture()

      author
      |> Ecto.Changeset.change(%{username: "author"})
      |> Repo.update!()

      Social.follow(user, author)

      {:ok, _public} =
        Social.create_snippet(author, snippet_attrs(%{visibility: :public, title: "Shared"}))

      {:ok, _private} =
        Social.create_snippet(author, snippet_attrs(%{visibility: :private, title: "Secret"}))

      activity = Social.following_activity(user)
      assert length(activity) == 1
      assert hd(activity).title == "Shared"
    end
  end

  describe "trending_snippets/1" do
    setup :create_user

    test "returns public snippets ordered by favorites", %{user: user} do
      {:ok, s1} =
        Social.create_snippet(user, snippet_attrs(%{visibility: :public, title: "Less Popular"}))

      {:ok, s2} =
        Social.create_snippet(user, snippet_attrs(%{visibility: :public, title: "Popular"}))

      # Favorite s2 twice
      u1 = user_fixture()
      u2 = user_fixture()
      Social.toggle_favorite(u1, s2)
      Social.toggle_favorite(u2, s2)

      # Favorite s1 once
      Social.toggle_favorite(u1, s1)

      trending = Social.trending_snippets()
      assert length(trending) == 2
      assert hd(trending).id == s2.id
    end
  end
end
