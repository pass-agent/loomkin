# Point Hound organization + vault config seeds
# Run: mix run priv/repo/seeds/ph_seeds.exs

alias Loomkin.Repo
alias Loomkin.Schemas.Organization
alias Loomkin.Schemas.OrganizationMembership
alias Loomkin.Schemas.VaultConfig

import Ecto.Query

# --- Organization ---

ph_org =
  case Repo.get_by(Organization, slug: "point-hound") do
    nil ->
      {:ok, org} =
        %Organization{}
        |> Organization.changeset(%{
          name: "Point Hound",
          slug: "point-hound",
          description: "Point Hound — first Loomkin vault customer"
        })
        |> Repo.insert()

      IO.puts("Created organization: Point Hound (#{org.id})")
      org

    org ->
      IO.puts("Organization already exists: Point Hound (#{org.id})")
      org
  end

# --- Membership: add first user (if any) ---

case Repo.one(from(u in Loomkin.Accounts.User, limit: 1)) do
  nil ->
    IO.puts("No users found — skipping membership. Create a user first, then re-run.")

  user ->
    case Repo.get_by(OrganizationMembership,
           organization_id: ph_org.id,
           user_id: user.id
         ) do
      nil ->
        {:ok, _membership} =
          %OrganizationMembership{}
          |> OrganizationMembership.changeset(%{
            role: :owner,
            organization_id: ph_org.id,
            user_id: user.id
          })
          |> Repo.insert()

        IO.puts("Added #{user.email} as owner of Point Hound")

      _existing ->
        IO.puts("#{user.email} already a member of Point Hound")
    end
end

# --- Vault Config ---

case Repo.get_by(VaultConfig, vault_id: "ph-vault") do
  nil ->
    {:ok, config} =
      %VaultConfig{}
      |> VaultConfig.changeset(%{
        vault_id: "ph-vault",
        name: "Point Hound Knowledge Base",
        description: "Team knowledge base for Point Hound",
        storage_type: "local",
        storage_config: %{"root" => "./priv/vaults/ph-vault"}
      })
      |> Repo.insert()

    # Set organization_id directly (not in cast)
    config
    |> Ecto.Changeset.change(%{organization_id: ph_org.id})
    |> Repo.update!()

    # Create local vault directory
    File.mkdir_p!("./priv/vaults/ph-vault")

    IO.puts("Created vault config: ph-vault (local storage for dev)")

  config ->
    # Ensure org binding
    if is_nil(config.organization_id) do
      config
      |> Ecto.Changeset.change(%{organization_id: ph_org.id})
      |> Repo.update!()

      IO.puts("Bound existing ph-vault to Point Hound org")
    else
      IO.puts("Vault config already exists: ph-vault")
    end
end

IO.puts("\nDone. Visit /vault/ph-vault to browse.")
