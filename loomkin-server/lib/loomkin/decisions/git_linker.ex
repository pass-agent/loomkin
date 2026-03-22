defmodule Loomkin.Decisions.GitLinker do
  @moduledoc "Links decision graph nodes to git commits."

  import Ecto.Query
  alias Loomkin.Repo
  alias Loomkin.Decisions.Graph
  alias Loomkin.Schemas.DecisionNode

  @all_edge_types [
    :leads_to,
    :chosen,
    :rejected,
    :requires,
    :blocks,
    :enables,
    :supersedes,
    :supports,
    :revises,
    :summarizes
  ]

  @doc "Find nodes with metadata.commit matching the given hash."
  def nodes_for_commit(commit_hash) when is_binary(commit_hash) do
    DecisionNode
    |> where([n], fragment("? ->> 'commit' = ?", n.metadata, ^commit_hash))
    |> Repo.all()
  end

  @doc "Walk downstream from a node, collecting commit hashes from metadata."
  def commits_for_node(node_id) when is_binary(node_id) do
    root = Graph.get_node(node_id)
    downstream = Graph.walk_downstream(node_id, @all_edge_types, max_depth: 10)
    downstream_nodes = Enum.map(downstream, fn {node, _depth, _type} -> node end)

    all_nodes = if root, do: [root | downstream_nodes], else: downstream_nodes

    all_nodes
    |> Enum.map(fn node -> get_in(node.metadata, ["commit"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Export all commits referenced in the graph with linked node IDs.

  Options:
    - :project_path - path to git repo (required for git log enrichment)
  """
  def export_history(opts \\ []) do
    project_path = Keyword.get(opts, :project_path)

    nodes_with_commits =
      DecisionNode
      |> where([n], fragment("? ->> 'commit' IS NOT NULL", n.metadata))
      |> Repo.all()

    commits_to_nodes =
      nodes_with_commits
      |> Enum.group_by(fn n -> n.metadata["commit"] end)
      |> Enum.map(fn {commit_hash, nodes} ->
        node_ids = Enum.map(nodes, & &1.id)
        git_info = if project_path, do: git_log_info(commit_hash, project_path), else: %{}
        Map.merge(%{commit: commit_hash, node_ids: node_ids}, git_info)
      end)

    {:ok, commits_to_nodes}
  end

  @doc """
  Auto-link unlinked action/outcome nodes to recent commits by keyword overlap.

  Options:
    - :project_path - path to git repo (required)
    - :limit - number of recent commits to check (default 50)
    - :min_overlap - minimum matching words (default 3)
  """
  def auto_link(opts \\ []) do
    project_path = Keyword.fetch!(opts, :project_path)
    limit = Keyword.get(opts, :limit, 50)
    min_overlap = Keyword.get(opts, :min_overlap, 3)

    unlinked_nodes =
      DecisionNode
      |> where([n], n.node_type in [:action, :outcome])
      |> where([n], n.status == :active)
      |> where([n], fragment("? ->> 'commit' IS NULL", n.metadata))
      |> Repo.all()

    recent_commits = recent_git_log(project_path, limit)

    linked =
      Enum.reduce(unlinked_nodes, [], fn node, acc ->
        case best_commit_match(node, recent_commits, min_overlap) do
          nil ->
            acc

          {commit_hash, _score} ->
            metadata = Map.put(node.metadata, "commit", commit_hash)
            {:ok, _updated} = Graph.update_node(node, %{metadata: metadata})
            [{node.id, commit_hash} | acc]
        end
      end)

    {:ok, Enum.reverse(linked)}
  end

  defp git_log_info(commit_hash, project_path) do
    format = "%an%n%aI%n%s"

    case System.cmd("git", ["log", "-1", "--format=#{format}", commit_hash],
           cd: project_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        lines = String.split(output, "\n", trim: true)

        case lines do
          [author, date, message | _] ->
            %{author: author, date: date, message: message}

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp recent_git_log(project_path, limit) do
    format = "%H%n%s"

    case System.cmd("git", ["log", "-#{limit}", "--format=#{format}"],
           cd: project_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.chunk_every(2)
        |> Enum.flat_map(fn
          [hash, message] -> [%{hash: hash, message: message}]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp best_commit_match(node, commits, min_overlap) do
    node_words = extract_words(node.title)

    commits
    |> Enum.map(fn %{hash: hash, message: message} ->
      commit_words = extract_words(message)
      overlap = MapSet.intersection(node_words, commit_words) |> MapSet.size()
      {hash, overlap}
    end)
    |> Enum.filter(fn {_hash, overlap} -> overlap >= min_overlap end)
    |> Enum.max_by(fn {_hash, overlap} -> overlap end, fn -> nil end)
  end

  defp extract_words(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp extract_words(_), do: MapSet.new()
end
