defmodule Loomkin.Vault.IndexTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Vault.Index

  @vault_id "test-vault"

  describe "upsert/1" do
    test "inserts a new entry" do
      assert {:ok, entry} =
               Index.upsert(%{
                 vault_id: @vault_id,
                 path: "notes/test.md",
                 title: "Test Note",
                 entry_type: "note",
                 body: "Hello world",
                 tags: ["test"]
               })

      assert entry.id
      assert entry.vault_id == @vault_id
      assert entry.path == "notes/test.md"
    end

    test "updates existing entry with same vault_id + path" do
      {:ok, _} =
        Index.upsert(%{vault_id: @vault_id, path: "notes/a.md", title: "V1", body: "first"})

      {:ok, updated} =
        Index.upsert(%{vault_id: @vault_id, path: "notes/a.md", title: "V2", body: "second"})

      assert updated.title == "V2"
      assert updated.body == "second"
      assert Index.count(@vault_id) == 1
    end
  end

  describe "get/2" do
    test "returns entry by vault_id and path" do
      {:ok, _} =
        Index.upsert(%{vault_id: @vault_id, path: "notes/find-me.md", title: "Find Me"})

      assert %{title: "Find Me"} = Index.get(@vault_id, "notes/find-me.md")
    end

    test "returns nil for non-existent entry" do
      assert nil == Index.get(@vault_id, "does/not/exist.md")
    end
  end

  describe "delete/2" do
    test "removes an existing entry" do
      {:ok, _} =
        Index.upsert(%{vault_id: @vault_id, path: "notes/delete-me.md", title: "Delete Me"})

      assert :ok = Index.delete(@vault_id, "notes/delete-me.md")
      assert nil == Index.get(@vault_id, "notes/delete-me.md")
    end

    test "returns error for non-existent entry" do
      assert {:error, :not_found} = Index.delete(@vault_id, "nope.md")
    end
  end

  describe "search/3" do
    setup do
      {:ok, _} =
        Index.upsert(%{
          vault_id: @vault_id,
          path: "notes/elixir.md",
          title: "Elixir Patterns",
          entry_type: "note",
          body: "GenServer and supervision trees are key patterns",
          tags: ["elixir", "otp"]
        })

      {:ok, _} =
        Index.upsert(%{
          vault_id: @vault_id,
          path: "notes/react.md",
          title: "React Hooks",
          entry_type: "note",
          body: "useState and useEffect are fundamental hooks",
          tags: ["react", "frontend"]
        })

      {:ok, _} =
        Index.upsert(%{
          vault_id: @vault_id,
          path: "meetings/standup.md",
          title: "Weekly Standup",
          entry_type: "meeting",
          body: "Discussed elixir deployment and react performance",
          tags: ["team"]
        })

      :ok
    end

    test "finds entries matching query" do
      results = Index.search(@vault_id, "elixir")
      assert length(results) >= 1
      paths = Enum.map(results, & &1.path)
      assert "notes/elixir.md" in paths
    end

    test "ranks title matches higher than body matches" do
      results = Index.search(@vault_id, "elixir")
      # The entry with "Elixir" in the title should rank first
      assert hd(results).path == "notes/elixir.md"
    end

    test "filters by entry_type" do
      results = Index.search(@vault_id, "elixir", entry_type: "meeting")
      assert length(results) == 1
      assert hd(results).entry_type == "meeting"
    end

    test "filters by tags" do
      results = Index.search(@vault_id, "elixir", tags: ["otp"])
      assert length(results) == 1
      assert hd(results).path == "notes/elixir.md"
    end

    test "returns empty for no matches" do
      assert [] = Index.search(@vault_id, "nonexistent_xyzzy")
    end
  end

  describe "fuzzy_search/3" do
    setup do
      {:ok, _} =
        Index.upsert(%{
          vault_id: @vault_id,
          path: "notes/twitter-strategy.md",
          title: "Twitter Strategy",
          entry_type: "note",
          body: "content"
        })

      {:ok, _} =
        Index.upsert(%{
          vault_id: @vault_id,
          path: "notes/twitch-streaming.md",
          title: "Twitch Streaming Setup",
          entry_type: "note",
          body: "content"
        })

      :ok
    end

    test "finds similar titles" do
      # typo in query
      results = Index.fuzzy_search(@vault_id, "Twitter Stratgy")
      assert length(results) >= 1
      assert hd(results).title == "Twitter Strategy"
    end
  end

  describe "list/2" do
    setup do
      {:ok, _} =
        Index.upsert(%{
          vault_id: @vault_id,
          path: "notes/a.md",
          title: "A",
          entry_type: "note",
          tags: ["alpha"]
        })

      {:ok, _} =
        Index.upsert(%{
          vault_id: @vault_id,
          path: "notes/b.md",
          title: "B",
          entry_type: "note",
          tags: ["beta"]
        })

      {:ok, _} =
        Index.upsert(%{
          vault_id: @vault_id,
          path: "meetings/c.md",
          title: "C",
          entry_type: "meeting",
          tags: ["alpha"]
        })

      :ok
    end

    test "lists all entries in a vault" do
      results = Index.list(@vault_id)
      assert length(results) == 3
    end

    test "filters by entry_type" do
      results = Index.list(@vault_id, entry_type: "note")
      assert length(results) == 2
    end

    test "filters by tags" do
      results = Index.list(@vault_id, tags: ["alpha"])
      assert length(results) == 2
    end

    test "supports limit and offset" do
      results = Index.list(@vault_id, limit: 1, offset: 1)
      assert length(results) == 1
    end
  end

  describe "count/2" do
    test "counts entries" do
      {:ok, _} = Index.upsert(%{vault_id: @vault_id, path: "a.md"})
      {:ok, _} = Index.upsert(%{vault_id: @vault_id, path: "b.md"})
      assert Index.count(@vault_id) == 2
    end
  end
end
