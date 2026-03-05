defmodule Loomkin.Decisions.GitLinkerTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Decisions.Graph
  alias Loomkin.Decisions.GitLinker

  defp node_attrs(overrides) do
    Map.merge(%{node_type: :goal, title: "Test goal"}, overrides)
  end

  describe "nodes_for_commit/1" do
    test "finds nodes tagged with a specific commit hash" do
      hash = "abc123def456"

      {:ok, _n1} =
        Graph.add_node(node_attrs(%{title: "Linked node", metadata: %{"commit" => hash}}))

      {:ok, _n2} =
        Graph.add_node(node_attrs(%{title: "Other node", metadata: %{"commit" => "other"}}))

      {:ok, _n3} = Graph.add_node(node_attrs(%{title: "No commit"}))

      results = GitLinker.nodes_for_commit(hash)
      assert length(results) == 1
      assert hd(results).title == "Linked node"
    end

    test "returns empty list when no nodes match" do
      assert GitLinker.nodes_for_commit("nonexistent") == []
    end
  end

  describe "commits_for_node/1" do
    test "collects commit hashes from node and descendants" do
      {:ok, root} =
        Graph.add_node(node_attrs(%{title: "Root", metadata: %{"commit" => "aaa111"}}))

      {:ok, child} =
        Graph.add_node(
          node_attrs(%{node_type: :action, title: "Child", metadata: %{"commit" => "bbb222"}})
        )

      {:ok, grandchild} =
        Graph.add_node(
          node_attrs(%{
            node_type: :outcome,
            title: "Grandchild",
            metadata: %{"commit" => "ccc333"}
          })
        )

      {:ok, _} = Graph.add_edge(root.id, child.id, :leads_to)
      {:ok, _} = Graph.add_edge(child.id, grandchild.id, :leads_to)

      commits = GitLinker.commits_for_node(root.id)
      assert "aaa111" in commits
      assert "bbb222" in commits
      assert "ccc333" in commits
      assert length(commits) == 3
    end

    test "skips nodes without commit metadata" do
      {:ok, root} =
        Graph.add_node(node_attrs(%{title: "Root", metadata: %{"commit" => "aaa111"}}))

      {:ok, child} = Graph.add_node(node_attrs(%{node_type: :action, title: "No commit child"}))

      {:ok, _} = Graph.add_edge(root.id, child.id, :leads_to)

      commits = GitLinker.commits_for_node(root.id)
      assert commits == ["aaa111"]
    end

    test "deduplicates commit hashes" do
      hash = "same_hash"

      {:ok, root} =
        Graph.add_node(node_attrs(%{title: "Root", metadata: %{"commit" => hash}}))

      {:ok, child} =
        Graph.add_node(
          node_attrs(%{node_type: :action, title: "Child", metadata: %{"commit" => hash}})
        )

      {:ok, _} = Graph.add_edge(root.id, child.id, :leads_to)

      commits = GitLinker.commits_for_node(root.id)
      assert commits == [hash]
    end
  end

  describe "export_history/1" do
    test "groups nodes by commit hash" do
      hash = "export_hash_1"

      {:ok, n1} =
        Graph.add_node(
          node_attrs(%{node_type: :action, title: "Action 1", metadata: %{"commit" => hash}})
        )

      {:ok, n2} =
        Graph.add_node(
          node_attrs(%{node_type: :outcome, title: "Outcome 1", metadata: %{"commit" => hash}})
        )

      {:ok, result} = GitLinker.export_history()

      assert length(result) == 1
      entry = hd(result)
      assert entry.commit == hash
      assert n1.id in entry.node_ids
      assert n2.id in entry.node_ids
    end

    test "returns empty list when no commits in graph" do
      {:ok, _} = Graph.add_node(node_attrs(%{title: "No commit node"}))
      {:ok, result} = GitLinker.export_history()
      assert result == []
    end
  end

  describe "auto_link/1" do
    test "links unlinked action nodes to matching commits" do
      # Create a temp git repo for testing
      tmp_dir =
        Path.join(System.tmp_dir!(), "git_linker_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

      File.write!(Path.join(tmp_dir, "auth.ex"), "defmodule Auth do end")
      System.cmd("git", ["add", "."], cd: tmp_dir)

      System.cmd("git", ["commit", "-m", "implement token refresh authentication flow"],
        cd: tmp_dir
      )

      {hash_output, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
      commit_hash = String.trim(hash_output)

      {:ok, _node} =
        Graph.add_node(
          node_attrs(%{
            node_type: :action,
            title: "Implement token refresh authentication flow"
          })
        )

      {:ok, linked} = GitLinker.auto_link(project_path: tmp_dir, min_overlap: 3)

      assert length(linked) == 1
      {_node_id, linked_hash} = hd(linked)
      assert linked_hash == commit_hash

      File.rm_rf!(tmp_dir)
    end

    test "does not link nodes below overlap threshold" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "git_linker_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

      File.write!(Path.join(tmp_dir, "readme.md"), "hello")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "initial commit"], cd: tmp_dir)

      {:ok, _node} =
        Graph.add_node(
          node_attrs(%{
            node_type: :action,
            title: "Completely unrelated quantum physics calculation"
          })
        )

      {:ok, linked} = GitLinker.auto_link(project_path: tmp_dir, min_overlap: 3)
      assert linked == []

      File.rm_rf!(tmp_dir)
    end

    test "skips already-linked nodes" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "git_linker_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      System.cmd("git", ["init"], cd: tmp_dir)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
      System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

      File.write!(Path.join(tmp_dir, "auth.ex"), "defmodule Auth do end")
      System.cmd("git", ["add", "."], cd: tmp_dir)
      System.cmd("git", ["commit", "-m", "implement token refresh flow"], cd: tmp_dir)

      {:ok, _node} =
        Graph.add_node(
          node_attrs(%{
            node_type: :action,
            title: "Implement token refresh flow",
            metadata: %{"commit" => "already_linked"}
          })
        )

      {:ok, linked} = GitLinker.auto_link(project_path: tmp_dir, min_overlap: 3)
      assert linked == []

      File.rm_rf!(tmp_dir)
    end
  end

  describe "Graph.list_nodes/1 branch filter" do
    test "filters nodes by branch in metadata" do
      {:ok, _} =
        Graph.add_node(
          node_attrs(%{title: "Feature node", metadata: %{"branch" => "feature/auth"}})
        )

      {:ok, _} =
        Graph.add_node(node_attrs(%{title: "Main node", metadata: %{"branch" => "main"}}))

      results = Graph.list_nodes(branch: "feature/auth")
      assert length(results) == 1
      assert hd(results).title == "Feature node"
    end
  end
end
