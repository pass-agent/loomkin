defmodule Loomkin.Vault do
  @moduledoc """
  Vault context — the public API for vault operations.
  Composes storage, index, sync, and parser into a unified interface.
  """

  require Logger

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.VaultConfig
  alias Loomkin.Schemas.VaultEntry
  alias Loomkin.Vault.Entry
  alias Loomkin.Vault.Index
  alias Loomkin.Vault.Parser
  alias Loomkin.Vault.Storage
  alias Loomkin.Vault.Sync
  alias Loomkin.Vault.Validators.Frontmatter
  alias Loomkin.Vault.Validators.TemporalLanguage

  @doc """
  Read a vault entry. Returns the parsed Entry struct.
  Reads from the index (PostgreSQL) by default for speed.
  """
  @spec read(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def read(vault_id, path) do
    case Index.get(vault_id, path) do
      nil ->
        {:error, :not_found}

      entry ->
        {:ok,
         %Entry{
           vault_id: entry.vault_id,
           path: entry.path,
           title: entry.title,
           entry_type: entry.entry_type,
           body: entry.body,
           metadata: entry.metadata,
           tags: entry.tags
         }}
    end
  end

  @doc """
  Write a vault entry. Persists to both storage AND index.
  Accepts either raw markdown content or an Entry struct.
  """
  @spec write(String.t(), String.t(), String.t() | Entry.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def write(vault_id, path, %Entry{} = entry) do
    content = Parser.serialize(entry)
    write(vault_id, path, content)
  end

  def write(vault_id, path, content) when is_binary(content) do
    with {:ok, config} <- get_config(vault_id),
         {adapter, opts} <- resolve_storage(config),
         :ok <- adapter.put(path, content, opts),
         {:ok, %Entry{} = parsed} <- Parser.parse(content) do
      checksum = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      attrs = %{
        vault_id: vault_id,
        path: path,
        title: parsed.title,
        entry_type: parsed.entry_type,
        body: parsed.body,
        metadata: parsed.metadata,
        tags: parsed.tags,
        checksum: checksum
      }

      case Index.upsert(attrs) do
        {:ok, _} ->
          entry_with_id = %Entry{parsed | vault_id: vault_id, path: path}
          run_validators(entry_with_id)
          Loomkin.Vault.FileSync.on_vault_write(vault_id, path, entry_with_id)
          {:ok, entry_with_id}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Write an Entry struct. Uses the entry's path. Convenience wrapper."
  @spec write_entry(String.t(), Entry.t()) :: {:ok, Entry.t()} | {:error, term()}
  def write_entry(vault_id, %Entry{path: path} = entry) when is_binary(path) do
    write(vault_id, path, entry)
  end

  @doc "Delete a vault entry from both storage and index."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(vault_id, path) do
    with {:ok, config} <- get_config(vault_id),
         {adapter, opts} <- resolve_storage(config),
         :ok <- adapter.delete(path, opts) do
      Index.delete(vault_id, path)
      :ok
    end
  end

  @doc "Search vault entries using full-text search."
  @spec search(String.t(), String.t(), keyword()) :: [map()]
  def search(vault_id, query, opts \\ []) do
    Index.search(vault_id, query, opts)
  end

  @doc "Fuzzy search vault entries by title."
  @spec fuzzy_search(String.t(), String.t(), keyword()) :: [map()]
  def fuzzy_search(vault_id, query, opts \\ []) do
    Index.fuzzy_search(vault_id, query, opts)
  end

  @doc "List vault entries with optional filters."
  @spec list(String.t(), keyword()) :: [map()]
  def list(vault_id, opts \\ []) do
    Index.list(vault_id, opts)
  end

  @doc "Get vault stats."
  @spec stats(String.t()) :: map()
  def stats(vault_id) do
    %{
      total_entries: Index.count(vault_id),
      by_type: count_by_type(vault_id)
    }
  end

  @doc "Run a full sync from storage to index."
  @spec sync(String.t()) :: {:ok, map()} | {:error, term()}
  def sync(vault_id) do
    with {:ok, config} <- get_config(vault_id),
         {adapter, opts} <- resolve_storage(config) do
      Sync.full_sync(vault_id, adapter, opts)
    end
  end

  @doc "Check sync status between storage and index."
  @spec check_sync(String.t()) :: {:ok, map()} | {:error, term()}
  def check_sync(vault_id) do
    with {:ok, config} <- get_config(vault_id),
         {adapter, opts} <- resolve_storage(config) do
      Sync.check_sync(vault_id, adapter, opts)
    end
  end

  @doc "Get a vault config by vault_id."
  @spec get_config(String.t()) :: {:ok, VaultConfig.t()} | {:error, term()}
  def get_config(vault_id) do
    case Repo.get_by(VaultConfig, vault_id: vault_id) do
      nil -> {:error, :vault_not_found}
      config -> {:ok, config}
    end
  end

  @doc "Create a new vault config."
  @spec create_vault(map()) :: {:ok, VaultConfig.t()} | {:error, Ecto.Changeset.t()}
  def create_vault(attrs) do
    %VaultConfig{}
    |> VaultConfig.changeset(attrs)
    |> Repo.insert()
  end

  # --- Private helpers ---

  defp run_validators(%Entry{} = entry) do
    entry_map = %{
      entry_type: entry.entry_type,
      body: entry.body,
      path: entry.path,
      metadata: entry.metadata
    }

    warnings =
      []
      |> collect_warning(:temporal_language, TemporalLanguage.validate(entry_map), entry.path)
      |> collect_warning(:missing_frontmatter, Frontmatter.validate(entry_map), entry.path)

    warnings
  end

  defp collect_warning(warnings, _key, :ok, _path), do: warnings

  defp collect_warning(warnings, :temporal_language, {:warn, vs}, path) do
    Logger.warning("[Vault] Temporal language in #{path}: #{inspect(vs)}")
    [{:temporal_language, vs} | warnings]
  end

  defp collect_warning(warnings, :missing_frontmatter, {:warn, info}, path) do
    Logger.warning("[Vault] Missing frontmatter in #{path}: #{inspect(info)}")
    [{:missing_frontmatter, info} | warnings]
  end

  defp resolve_storage(%VaultConfig{storage_type: type, storage_config: config}) do
    adapter = Storage.adapter(type)
    opts = storage_config_to_opts(type, config)
    {adapter, opts}
  end

  defp storage_config_to_opts("local", config) do
    [root: config["root"] || config[:root] || "./vault"]
  end

  defp storage_config_to_opts("s3", config) do
    [
      bucket: config["bucket"] || config[:bucket],
      prefix: config["prefix"] || config[:prefix] || "vault/",
      region: config["region"] || config[:region] || "auto",
      endpoint: config["endpoint"] || config[:endpoint],
      access_key_id: config["access_key_id"] || config[:access_key_id],
      secret_access_key: config["secret_access_key"] || config[:secret_access_key]
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp count_by_type(vault_id) do
    from(e in VaultEntry,
      where: e.vault_id == ^vault_id,
      group_by: e.entry_type,
      select: {e.entry_type, count(e.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
