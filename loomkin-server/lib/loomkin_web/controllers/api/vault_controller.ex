defmodule LoomkinWeb.Api.VaultController do
  use LoomkinWeb, :controller

  alias Loomkin.Vault

  action_fallback LoomkinWeb.Api.FallbackController

  @doc """
  GET /api/v1/vaults
  List vaults accessible to the current user.
  """
  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    vaults = Vault.list_vaults_for_user(user)

    json(conn, %{
      vaults:
        Enum.map(vaults, fn vc ->
          %{
            id: vc.id,
            vault_id: vc.vault_id,
            name: vc.name,
            description: vc.description,
            storage_type: vc.storage_type,
            organization_id: vc.organization_id,
            entry_count: Vault.Index.count(vc.vault_id)
          }
        end)
    })
  end

  @doc """
  GET /api/v1/vaults/:vault_id
  Show a single vault with stats.
  """
  def show(conn, %{"vault_id" => vault_id}) do
    user = conn.assigns.current_scope.user

    with {:ok, config} <- Vault.get_config(vault_id),
         true <- Vault.user_can_access_vault?(user, config) do
      stats = Vault.stats(vault_id)

      json(conn, %{
        vault: %{
          id: config.id,
          vault_id: config.vault_id,
          name: config.name,
          description: config.description,
          storage_type: config.storage_type,
          organization_id: config.organization_id
        },
        stats: stats
      })
    else
      false ->
        conn |> put_status(:forbidden) |> json(%{error: "access_denied"})

      {:error, :vault_not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  GET /api/v1/vaults/:vault_id/search?q=query
  Search entries within a vault.
  """
  def search(conn, %{"vault_id" => vault_id, "q" => query}) do
    user = conn.assigns.current_scope.user

    with {:ok, config} <- Vault.get_config(vault_id),
         true <- Vault.user_can_access_vault?(user, config) do
      results = Vault.search(vault_id, query)
      json(conn, %{results: results})
    else
      false ->
        conn |> put_status(:forbidden) |> json(%{error: "access_denied"})

      {:error, :vault_not_found} ->
        {:error, :not_found}
    end
  end

  def search(conn, %{"vault_id" => _vault_id}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "missing_query", message: "q parameter is required"})
  end
end
