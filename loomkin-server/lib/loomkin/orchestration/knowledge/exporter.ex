defmodule Loomkin.Orchestration.Knowledge.Exporter do
  @moduledoc """
  Writes the knowledge store out to an interoperable JSONL file.

  Field names are converted back to camelCase (`affected_files →
  affectedFiles`, `inserted_at → createdAt`). The round-trip with
  `Importer` preserves all data.
  """

  alias Loomkin.Orchestration.KnowledgeStore
  alias Loomkin.Orchestration.Schema.KnowledgeFact

  @doc """
  Writes all (or filtered) facts to `path`. Returns `{:ok, count}`.
  """
  @spec export_file(Path.t(), map(), GenServer.name()) :: {:ok, non_neg_integer()}
  def export_file(path, filters \\ %{}, store \\ KnowledgeStore) do
    facts = KnowledgeStore.list_facts(filters, store)
    write_facts(path, facts)
  end

  @doc "Writes a pre-loaded list of facts."
  @spec write_facts(Path.t(), [KnowledgeFact.t()]) :: {:ok, non_neg_integer()}
  def write_facts(path, facts) when is_list(facts) do
    File.mkdir_p!(Path.dirname(path))

    lines =
      facts
      |> Enum.map(&to_jsonl/1)
      |> Enum.intersperse("\n")

    File.write!(path, [lines, "\n"])
    {:ok, length(facts)}
  end

  defp to_jsonl(%KnowledgeFact{} = f) do
    %{
      "id" => f.external_id || f.id,
      "type" => Atom.to_string(f.type),
      "fact" => f.fact,
      "recommendation" => f.recommendation,
      "confidence" => Atom.to_string(f.confidence),
      "provenance" => f.provenance || [],
      "tags" => f.tags || [],
      "affectedFiles" => f.affected_files || [],
      "createdAt" => format_ts(f.inserted_at)
    }
    |> Jason.encode!()
  end

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
