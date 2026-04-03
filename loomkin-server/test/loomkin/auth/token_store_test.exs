defmodule Loomkin.Auth.TokenStore.SchemaTest do
  use ExUnit.Case, async: true

  alias Loomkin.Schemas.AuthToken

  describe "AuthToken changeset" do
    test "valid with required fields" do
      changeset =
        AuthToken.changeset(%AuthToken{}, %{
          provider: "anthropic",
          access_token_encrypted: <<1, 2, 3>>
        })

      assert changeset.valid?
    end

    test "invalid without provider" do
      changeset =
        AuthToken.changeset(%AuthToken{}, %{
          access_token_encrypted: <<1, 2, 3>>
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :provider)
    end

    test "invalid without access_token_encrypted" do
      changeset = AuthToken.changeset(%AuthToken{}, %{provider: "anthropic"})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :access_token_encrypted)
    end

    test "accepts all optional fields" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        AuthToken.changeset(%AuthToken{}, %{
          provider: "google",
          access_token_encrypted: <<1, 2, 3>>,
          refresh_token_encrypted: <<4, 5, 6>>,
          expires_at: now,
          account_id: "acct_123",
          scopes: "read write",
          metadata: %{"key" => "value"}
        })

      assert changeset.valid?
    end
  end
end

defmodule Loomkin.Auth.TokenStore.IntegrationTest do
  use Loomkin.DataCase, async: false

  alias Loomkin.Auth.TokenStore
  alias Loomkin.Schemas.AuthToken

  setup do
    pid = Process.whereis(TokenStore)

    unless pid do
      flunk("TokenStore GenServer is not running — cannot run integration tests")
    end

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

    on_exit(fn ->
      TokenStore.revoke_tokens(:anthropic)
      TokenStore.revoke_tokens(:google)
      TokenStore.revoke_tokens(:openai)
    end)

    :ok
  end

  describe "AuthToken DB operations" do
    test "can insert and retrieve from DB" do
      {:ok, token} =
        %AuthToken{}
        |> AuthToken.changeset(%{
          provider: "anthropic_test_#{System.unique_integer([:positive])}",
          access_token_encrypted: <<0, 1, 2, 3>>,
          account_id: "test_account"
        })
        |> Repo.insert()

      assert token.id != nil
      assert token.account_id == "test_account"

      retrieved = Repo.get!(AuthToken, token.id)
      assert retrieved.account_id == "test_account"
    end

    test "provider uniqueness constraint" do
      provider = "unique_test_#{System.unique_integer([:positive])}"
      attrs = %{provider: provider, access_token_encrypted: <<1, 2, 3>>}

      {:ok, _} =
        %AuthToken{}
        |> AuthToken.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %AuthToken{}
        |> AuthToken.changeset(attrs)
        |> Repo.insert()

      assert Keyword.has_key?(changeset.errors, :provider)
    end
  end

  describe "store_tokens/2 and get_access_token/1" do
    test "stores and retrieves a token" do
      TokenStore.revoke_tokens(:anthropic)

      token_data = %{
        access_token: "test_access_token_#{System.unique_integer([:positive])}",
        refresh_token: "test_refresh_token",
        expires_in: 3600
      }

      assert :ok = TokenStore.store_tokens(:anthropic, token_data)
      assert token_data.access_token == TokenStore.get_access_token(:anthropic)
    end

    test "returns nil for provider without stored token" do
      TokenStore.revoke_tokens(:google)
      assert nil == TokenStore.get_access_token(:google)
    end
  end

  describe "revoke_tokens/1" do
    test "removes token from cache and DB" do
      token_data = %{
        access_token: "to_be_revoked_#{System.unique_integer([:positive])}",
        expires_in: 3600
      }

      TokenStore.store_tokens(:anthropic, token_data)
      assert TokenStore.get_access_token(:anthropic) != nil

      assert :ok = TokenStore.revoke_tokens(:anthropic)
      assert nil == TokenStore.get_access_token(:anthropic)
    end
  end

  describe "connected?/1" do
    test "returns true when token exists" do
      TokenStore.revoke_tokens(:anthropic)

      token_data = %{
        access_token: "connected_test_#{System.unique_integer([:positive])}",
        expires_in: 3600
      }

      TokenStore.store_tokens(:anthropic, token_data)
      assert TokenStore.connected?(:anthropic)
    end

    test "returns false when no token" do
      TokenStore.revoke_tokens(:google)
      refute TokenStore.connected?(:google)
    end
  end

  describe "get_status/1" do
    test "returns status map without raw tokens" do
      TokenStore.revoke_tokens(:anthropic)

      token_data = %{
        access_token: "status_test_#{System.unique_integer([:positive])}",
        refresh_token: "refresh_status_test",
        expires_in: 3600,
        account_id: "acct_status",
        scopes: "read write"
      }

      TokenStore.store_tokens(:anthropic, token_data)
      status = TokenStore.get_status(:anthropic)

      assert status != nil
      assert status.connected == true
      refute Map.has_key?(status, :access_token)
      refute Map.has_key?(status, :refresh_token)
    end

    test "returns nil for disconnected provider" do
      TokenStore.revoke_tokens(:google)
      assert nil == TokenStore.get_status(:google)
    end
  end

  describe "all_statuses/0" do
    test "returns a map of provider => status" do
      statuses = TokenStore.all_statuses()
      assert is_map(statuses)

      for {_provider, status} <- statuses do
        assert Map.has_key?(status, :connected)
      end
    end
  end
end
