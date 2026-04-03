defmodule Loomkin.Vault do
  @moduledoc """
  Vault context — the public API for vault operations.
  All storage is PostgreSQL-backed via the index. No file storage adapters.
  """

  require Logger

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.OrganizationMembership
  alias Loomkin.Schemas.VaultConfig
  alias Loomkin.Schemas.VaultEntry
  alias Loomkin.Vault.Entry
  alias Loomkin.Vault.Index
  alias Loomkin.Vault.Parser
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
  Write a vault entry to PostgreSQL.
  Accepts either raw markdown content or an Entry struct.
  """
  @spec write(String.t(), String.t(), String.t() | Entry.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def write(vault_id, path, %Entry{} = entry) do
    content = Parser.serialize(entry)
    write(vault_id, path, content)
  end

  def write(vault_id, path, content) when is_binary(content) do
    with {:ok, %Entry{} = parsed} <- Parser.parse(content) do
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

  @doc "Delete a vault entry from the index."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(vault_id, path) do
    Index.delete(vault_id, path)
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

  @doc "Get a vault config by slug (vault_id). Raises if not found."
  @spec get_vault_by_slug!(String.t()) :: VaultConfig.t()
  def get_vault_by_slug!(slug) do
    Repo.get_by!(VaultConfig, vault_id: slug)
  end

  @doc "List vaults accessible to a user via their org memberships."
  @spec list_vaults_for_user(map()) :: [VaultConfig.t()]
  def list_vaults_for_user(user) do
    org_ids =
      from(m in OrganizationMembership,
        where: m.user_id == ^user.id,
        select: m.organization_id
      )
      |> Repo.all()

    from(vc in VaultConfig,
      where: vc.organization_id in ^org_ids or is_nil(vc.organization_id),
      order_by: [asc: vc.name]
    )
    |> Repo.all()
  end

  @doc "List vaults belonging to an organization."
  @spec list_vaults_for_org(String.t()) :: [VaultConfig.t()]
  def list_vaults_for_org(org_id) do
    from(vc in VaultConfig, where: vc.organization_id == ^org_id, order_by: vc.name)
    |> Repo.all()
  end

  @doc "Check if a user can access a vault via org membership."
  @spec user_can_access_vault?(map(), VaultConfig.t()) :: boolean()
  def user_can_access_vault?(user, %VaultConfig{organization_id: nil}), do: user != nil

  def user_can_access_vault?(nil, _vault_config), do: false

  def user_can_access_vault?(user, %VaultConfig{organization_id: org_id}) do
    from(m in Loomkin.Schemas.OrganizationMembership,
      where: m.organization_id == ^org_id and m.user_id == ^user.id
    )
    |> Repo.exists?()
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
