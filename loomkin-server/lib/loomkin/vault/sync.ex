defmodule Loomkin.Vault.Sync do
  @moduledoc """
  Synchronizes vault entries between storage (files) and index (PostgreSQL).
  """

  alias Loomkin.Vault.Index
  alias Loomkin.Vault.Parser

  @doc """
  Full sync: read all files from storage and upsert into the index.
  Returns {:ok, %{synced: count, errors: [...], total: count}}
  """
  @spec full_sync(String.t(), module(), keyword()) :: {:ok, map()}
  def full_sync(vault_id, adapter, storage_opts) do
    {:ok, paths} = adapter.list("", storage_opts)

    md_paths = Enum.filter(paths, &String.ends_with?(&1, ".md"))

    results =
      Enum.map(md_paths, fn path ->
        sync_entry(vault_id, path, adapter, storage_opts)
      end)

    synced = Enum.count(results, &match?({:ok, :synced}, &1))

    errors =
      results
      |> Enum.filter(&match?({:error, _, _}, &1))
      |> Enum.map(fn {:error, path, reason} -> {path, reason} end)

    {:ok, %{synced: synced, errors: errors, total: length(md_paths)}}
  end

  @doc """
  Sync a single entry from storage to index.
  Reads the file, parses it, computes checksum, and upserts if changed.
  """
  @spec sync_entry(String.t(), String.t(), module(), keyword()) ::
          {:ok, :synced | :unchanged} | {:error, String.t(), term()}
  def sync_entry(vault_id, path, adapter, storage_opts) do
    case adapter.get(path, storage_opts) do
      {:ok, content} ->
        checksum = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

        case Index.get(vault_id, path) do
          %{checksum: ^checksum} ->
            {:ok, :unchanged}

          _existing_or_nil ->
            case Parser.parse(content) do
              {:ok, entry} ->
                attrs = %{
                  vault_id: vault_id,
                  path: path,
                  title: entry.title,
                  entry_type: entry.entry_type,
                  body: entry.body,
                  metadata: entry.metadata,
                  tags: entry.tags,
                  checksum: checksum
                }

                case Index.upsert(attrs) do
                  {:ok, _} -> {:ok, :synced}
                  {:error, changeset} -> {:error, path, changeset}
                end

              {:error, reason} ->
                {:error, path, reason}
            end
        end

      {:error, reason} ->
        {:error, path, reason}
    end
  end

  @doc """
  Remove an entry from the index (when file is deleted from storage).
  """
  @spec remove_entry(String.t(), String.t()) :: :ok | {:error, :not_found}
  def remove_entry(vault_id, path) do
    Index.delete(vault_id, path)
  end

  @doc """
  Check if storage and index are in sync for a vault.
  Returns a map with :in_sync (boolean), :storage_only paths, :index_only paths.
  """
  @spec check_sync(String.t(), module(), keyword()) :: {:ok, map()}
  def check_sync(vault_id, adapter, storage_opts) do
    {:ok, storage_paths} = adapter.list("", storage_opts)
    storage_set = storage_paths |> Enum.filter(&String.ends_with?(&1, ".md")) |> MapSet.new()

    index_entries = Index.list(vault_id, limit: 10_000)
    index_set = index_entries |> Enum.map(& &1.path) |> MapSet.new()

    storage_only = MapSet.difference(storage_set, index_set) |> MapSet.to_list()
    index_only = MapSet.difference(index_set, storage_set) |> MapSet.to_list()

    {:ok,
     %{
       in_sync: storage_only == [] and index_only == [],
       storage_only: storage_only,
       index_only: index_only,
       storage_count: MapSet.size(storage_set),
       index_count: MapSet.size(index_set)
     }}
  end
end
