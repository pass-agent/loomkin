defmodule Loomkin.Orchestration.Knowledge.Importer do
  @moduledoc """
  Reads interoperable JSONL knowledge format files into the knowledge store.

  Each line is one fact:

      {"id":"...","type":"pattern","fact":"...","recommendation":"...",
       "confidence":"high","provenance":[...],"tags":[...],"affectedFiles":[...]}

  Keys are normalized: `affectedFiles → affected_files`, `createdAt` is
  parsed as ISO-8601 and stored in `inserted_at`. Unknown fields are
  dropped silently.
  """

  alias Loomkin.Orchestration.KnowledgeStore

  @doc """
  Import a JSONL file. Returns `{:ok, %{imported: n, errors: [...]}}`.
  """
  @spec import_file(Path.t(), GenServer.name()) ::
          {:ok, %{imported: non_neg_integer(), errors: [String.t()]}}
  def import_file(path, store \\ KnowledgeStore) do
    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.reduce({0, []}, fn {line, lineno}, {ok, errs} ->
      case import_line(line, store) do
        :ok -> {ok + 1, errs}
        {:error, why} -> {ok, ["line #{lineno}: #{inspect(why)}" | errs]}
      end
    end)
    |> then(fn {ok, errs} -> {:ok, %{imported: ok, errors: Enum.reverse(errs)}} end)
  end

  defp import_line(line, store) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :ok
    else
      with {:ok, decoded} <- Jason.decode(trimmed),
           {:ok, attrs} <- normalize(decoded),
           {:ok, _fact} <- KnowledgeStore.put_fact(attrs, store) do
        :ok
      else
        {:error, %Ecto.Changeset{} = cs} ->
          {:error, format_changeset(cs)}

        other ->
          other
      end
    end
  end

  @doc false
  def normalize(map) when is_map(map) do
    attrs = %{
      id: Ecto.UUID.generate(),
      external_id: map["id"],
      type: parse_type(map["type"]),
      fact: map["fact"],
      recommendation: map["recommendation"],
      confidence: parse_confidence(map["confidence"]),
      provenance: map["provenance"] || [],
      tags: map["tags"] || [],
      affected_files: map["affectedFiles"] || map["affected_files"] || []
    }

    case parse_timestamp(map["createdAt"] || map["created_at"]) do
      nil -> {:ok, attrs}
      ts -> {:ok, Map.put(attrs, :inserted_at, ts)}
    end
  end

  defp parse_type(nil), do: nil
  defp parse_type(t) when is_atom(t), do: t

  defp parse_type(t) when is_binary(t) do
    cond do
      String.contains?(t, "-") ->
        t |> String.replace("-", "_") |> String.to_atom()

      true ->
        String.to_atom(t)
    end
  end

  defp parse_confidence(nil), do: :medium
  defp parse_confidence(c) when is_atom(c), do: c
  defp parse_confidence(c) when is_binary(c), do: String.to_atom(c)

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp format_changeset(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map_join("; ", fn {k, {msg, _}} -> "#{k} #{msg}" end)
  end
end
