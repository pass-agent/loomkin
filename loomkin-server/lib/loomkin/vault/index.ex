defmodule Loomkin.Vault.Index do
  @moduledoc """
  PostgreSQL-backed search index for vault entries.
  Provides upsert, delete, search, list, and get operations.
  """

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultEntry

  @doc "Insert or update a vault entry in the index."
  @spec upsert(map()) :: {:ok, VaultEntry.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) when is_map(attrs) do
    %VaultEntry{}
    |> VaultEntry.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:vault_id, :path],
      returning: true
    )
  end

  @doc "Delete a vault entry by vault_id and path."
  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(vault_id, path) do
    case get(vault_id, path) do
      nil ->
        {:error, :not_found}

      entry ->
        case Repo.delete(entry) do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc "Get a single entry by vault_id and path."
  @spec get(String.t(), String.t()) :: VaultEntry.t() | nil
  def get(vault_id, path) do
    Repo.get_by(VaultEntry, vault_id: vault_id, path: path)
  end

  @doc """
  Full-text search across vault entries.

  Returns entries ranked by relevance. Supports:
  - Plain text queries (automatically converted to tsquery via websearch_to_tsquery)
  - Filtering by vault_id
  - Filtering by entry_type
  - Filtering by tags (containment)
  - Limit/offset for pagination
  """
  @spec search(String.t(), String.t(), keyword()) :: [VaultEntry.t()]
  def search(vault_id, query, opts \\ []) do
    entry_type = Keyword.get(opts, :entry_type)
    tags = Keyword.get(opts, :tags)
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    from(e in VaultEntry,
      where: e.vault_id == ^vault_id,
      where:
        fragment(
          "search_vector @@ websearch_to_tsquery('english', ?)",
          ^query
        ),
      order_by: [
        desc:
          fragment(
            "ts_rank_cd(search_vector, websearch_to_tsquery('english', ?), 32)",
            ^query
          )
      ],
      limit: ^limit,
      offset: ^offset
    )
    |> maybe_filter_type(entry_type)
    |> maybe_filter_tags(tags)
    |> Repo.all()
  end

  @doc """
  Fuzzy search by title using pg_trgm similarity.
  Returns entries with titles similar to the query, ordered by similarity.
  """
  @spec fuzzy_search(String.t(), String.t(), keyword()) :: [VaultEntry.t()]
  def fuzzy_search(vault_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.3)

    from(e in VaultEntry,
      where: e.vault_id == ^vault_id,
      where: fragment("similarity(?, ?) > ?", e.title, ^query, ^threshold),
      order_by: [desc: fragment("similarity(?, ?)", e.title, ^query)],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "List vault entries with optional filters."
  @spec list(String.t(), keyword()) :: [VaultEntry.t()]
  def list(vault_id, opts \\ []) do
    entry_type = Keyword.get(opts, :entry_type)
    tags = Keyword.get(opts, :tags)
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    order_by = Keyword.get(opts, :order_by, :path)

    from(e in VaultEntry,
      where: e.vault_id == ^vault_id,
      order_by: ^order_by,
      limit: ^limit,
      offset: ^offset
    )
    |> maybe_filter_type(entry_type)
    |> maybe_filter_tags(tags)
    |> Repo.all()
  end

  @doc "Count entries in a vault, optionally filtered by type."
  @spec count(String.t(), keyword()) :: non_neg_integer()
  def count(vault_id, opts \\ []) do
    entry_type = Keyword.get(opts, :entry_type)

    from(e in VaultEntry, where: e.vault_id == ^vault_id)
    |> maybe_filter_type(entry_type)
    |> Repo.aggregate(:count)
  end

  defp maybe_filter_type(query, nil), do: query

  defp maybe_filter_type(query, type) do
    from(e in query, where: e.entry_type == ^type)
  end

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, []), do: query

  defp maybe_filter_tags(query, tags) when is_list(tags) do
    from(e in query, where: fragment("tags @> ?", ^tags))
  end
end
