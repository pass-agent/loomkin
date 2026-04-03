defmodule Loomkin.Auth.TokenStore do
  @moduledoc """
  Encrypted token persistence and in-memory cache for OAuth provider tokens.

  Tokens are encrypted at rest in the database using `Plug.Crypto.MessageEncryptor`
  with a key derived from the application's `secret_key_base`. An ETS table
  provides fast reads so the hot path (every LLM request) never hits the DB.

  ## Lifecycle

  1. `store_tokens/2` — encrypts and persists tokens, updates ETS cache, schedules refresh
  2. `get_access_token/1` — reads from ETS cache (decrypted plaintext)
  3. Refresh timer fires ~5 min before expiry, calls the provider's refresh endpoint
  4. `revoke_tokens/1` — deletes from DB and ETS, broadcasts disconnect

  ## PubSub

  Broadcasts on `"auth:status"` topic:
  - `{:auth_connected, provider}` — after successful token store
  - `{:auth_disconnected, provider}` — after revocation
  - `{:auth_refreshed, provider}` — after successful refresh
  - `{:auth_refresh_failed, provider, reason}` — after failed refresh
  """

  use GenServer

  alias Loomkin.Auth.ProviderRegistry
  alias Loomkin.Repo
  alias Loomkin.Schemas.AuthToken

  import Ecto.Query

  @table :loomkin_auth_tokens
  # @pubsub_topic removed — auth events now go through Loomkin.Signals
  @refresh_buffer_seconds 300
  @max_refresh_retries 3
  @initial_retry_delay_ms 15_000

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store OAuth tokens for a provider. Encrypts and persists to DB,
  updates in-memory cache, and schedules automatic refresh.

  ## Params

  - `provider` — atom, e.g. `:anthropic`
  - `token_data` — map with keys:
    - `:access_token` (required) — plaintext access token
    - `:refresh_token` — plaintext refresh token (optional)
    - `:expires_in` — seconds until expiry (optional)
    - `:account_id` — provider account identifier (optional)
    - `:scopes` — space-separated scope string (optional)
    - `:metadata` — arbitrary map (optional)
  """
  @spec store_tokens(atom(), map()) :: :ok | {:error, term()}
  def store_tokens(provider, token_data) do
    GenServer.call(__MODULE__, {:store_tokens, provider, token_data})
  end

  @doc """
  Returns the decrypted access token for the given provider, or `nil`
  if no token is stored or the token has expired.
  """
  @spec get_access_token(atom()) :: String.t() | nil
  def get_access_token(provider) do
    case :ets.lookup(@table, provider) do
      [{^provider, %{access_token: token, expires_at: expires_at}}] ->
        if expires_at == nil or DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          token
        else
          nil
        end

      [] ->
        nil
    end
  end

  @doc """
  Returns the full cached token info for a provider (without the raw tokens),
  useful for status display in the UI.
  """
  @spec get_status(atom()) :: map() | nil
  def get_status(provider) do
    case :ets.lookup(@table, provider) do
      [{^provider, info}] ->
        info
        |> Map.drop([:access_token, :refresh_token])
        |> Map.put(:connected, true)
        |> Map.put(:expired, token_expired?(info))

      [] ->
        nil
    end
  end

  @doc """
  Returns status info for all connected providers.
  """
  @spec all_statuses() :: %{atom() => map()}
  def all_statuses do
    @table
    |> :ets.tab2list()
    |> Enum.into(%{}, fn {provider, info} ->
      status =
        info
        |> Map.drop([:access_token, :refresh_token])
        |> Map.put(:connected, true)
        |> Map.put(:expired, token_expired?(info))

      {provider, status}
    end)
  end

  @doc """
  Revoke (delete) tokens for a provider. Removes from DB and cache.
  """
  @spec revoke_tokens(atom()) :: :ok
  def revoke_tokens(provider) do
    GenServer.call(__MODULE__, {:revoke_tokens, provider})
  end

  @doc """
  Check if a provider has a valid (non-expired) OAuth token.
  """
  @spec connected?(atom()) :: boolean()
  def connected?(provider) do
    get_access_token(provider) != nil
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    state = %{
      table: table,
      refresh_timers: %{},
      encryption_key: nil
    }

    {:ok, state, {:continue, :load_tokens}}
  end

  @impl true
  def handle_continue(:load_tokens, state) do
    key = derive_encryption_key()
    state = %{state | encryption_key: key}

    tokens = Repo.all(AuthToken)

    for token <- tokens do
      case safe_to_atom(token.provider) do
        {:ok, provider} -> load_token_into_cache(token, key, provider)
        :error -> :ok
      end
    end

    refresh_timers =
      tokens
      |> Enum.reduce(%{}, fn token, timers ->
        case safe_to_atom(token.provider) do
          {:ok, provider} ->
            case schedule_refresh(provider, token.expires_at) do
              {:ok, timer_ref} -> Map.put(timers, provider, timer_ref)
              :no_refresh -> timers
            end

          :error ->
            timers
        end
      end)

    {:noreply, %{state | refresh_timers: refresh_timers}}
  end

  @impl true
  def handle_call({:store_tokens, provider, token_data}, _from, state) do
    case persist_and_cache(provider, token_data, state) do
      {:ok, new_state} ->
        broadcast({:auth_connected, provider})
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:revoke_tokens, provider}, _from, state) do
    provider_str = Atom.to_string(provider)

    from(t in AuthToken, where: t.provider == ^provider_str)
    |> Repo.delete_all()

    :ets.delete(@table, provider)

    state = cancel_refresh_timer(state, provider)

    broadcast({:auth_disconnected, provider})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:refresh_token, provider}, state) do
    handle_refresh_with_retry(provider, state, 0)
  end

  @impl true
  def handle_info({:refresh_retry, provider, attempt}, state) do
    handle_refresh_with_retry(provider, state, attempt)
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Shared persist + cache logic ───────────────────────────────────

  defp persist_and_cache(provider, token_data, state) do
    provider_str = Atom.to_string(provider)
    key = state.encryption_key

    access_encrypted = encrypt(token_data.access_token, key)
    refresh_encrypted = if token_data[:refresh_token], do: encrypt(token_data.refresh_token, key)

    expires_at =
      if token_data[:expires_in] do
        DateTime.utc_now()
        |> DateTime.add(token_data.expires_in, :second)
        |> DateTime.truncate(:second)
      end

    attrs = %{
      provider: provider_str,
      access_token_encrypted: access_encrypted,
      refresh_token_encrypted: refresh_encrypted,
      expires_at: expires_at,
      account_id: token_data[:account_id],
      scopes: token_data[:scopes],
      metadata: token_data[:metadata] || %{}
    }

    result =
      case Repo.get_by(AuthToken, provider: provider_str) do
        nil -> %AuthToken{}
        existing -> existing
      end
      |> AuthToken.changeset(attrs)
      |> Repo.insert_or_update()

    case result do
      {:ok, record} ->
        cache_entry = %{
          access_token: token_data.access_token,
          refresh_token: token_data[:refresh_token],
          expires_at: record.expires_at,
          account_id: record.account_id,
          scopes: record.scopes,
          provider: provider
        }

        :ets.insert(@table, {provider, cache_entry})

        state = cancel_refresh_timer(state, provider)

        state =
          case schedule_refresh(provider, record.expires_at) do
            {:ok, timer_ref} -> put_in(state.refresh_timers[provider], timer_ref)
            :no_refresh -> state
          end

        {:ok, state}

      {:error, changeset} ->
        {:error, {:db_write_failed, changeset.errors}}
    end
  end

  # ── Encryption ──────────────────────────────────────────────────────

  defp derive_encryption_key do
    secret_key_base =
      Application.get_env(:loomkin, LoomkinWeb.Endpoint)[:secret_key_base] ||
        raise "secret_key_base not configured — cannot encrypt tokens"

    Plug.Crypto.KeyGenerator.generate(secret_key_base, "loomkin_token_encryption", length: 64)
  end

  defp encrypt(plaintext, key) do
    <<enc_key::binary-32, sign_key::binary-32>> = key
    Plug.Crypto.MessageEncryptor.encrypt(plaintext, "", enc_key, sign_key)
  end

  defp decrypt(ciphertext, key) do
    <<enc_key::binary-32, sign_key::binary-32>> = key

    case Plug.Crypto.MessageEncryptor.decrypt(ciphertext, "", enc_key, sign_key) do
      {:ok, plaintext} -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  end

  # ── Internal helpers ────────────────────────────────────────────────

  defp safe_to_atom(provider_str) when is_binary(provider_str) do
    known = ProviderRegistry.provider_id_strings()

    if provider_str in known do
      {:ok, String.to_existing_atom(provider_str)}
    else
      :error
    end
  end

  defp load_token_into_cache(%AuthToken{} = token, key, provider) do
    case decrypt(token.access_token_encrypted, key) do
      {:ok, access_token} ->
        refresh_token =
          if token.refresh_token_encrypted do
            case decrypt(token.refresh_token_encrypted, key) do
              {:ok, rt} -> rt
              {:error, _} -> nil
            end
          end

        cache_entry = %{
          access_token: access_token,
          refresh_token: refresh_token,
          expires_at: token.expires_at,
          account_id: token.account_id,
          scopes: token.scopes,
          provider: provider
        }

        :ets.insert(@table, {provider, cache_entry})
        :ok

      {:error, _reason} ->
        :error
    end
  end

  defp schedule_refresh(_provider, nil), do: :no_refresh

  defp schedule_refresh(provider, %DateTime{} = expires_at) do
    now = DateTime.utc_now()
    seconds_until_expiry = DateTime.diff(expires_at, now, :second)
    refresh_in = max(seconds_until_expiry - @refresh_buffer_seconds, 10)

    if seconds_until_expiry > 0 do
      timer_ref = Process.send_after(self(), {:refresh_token, provider}, refresh_in * 1000)
      {:ok, timer_ref}
    else
      # Token already expired — attempt an immediate refresh (the handler
      # will use the cached refresh_token from ETS if one exists)
      timer_ref = Process.send_after(self(), {:refresh_token, provider}, 1_000)
      {:ok, timer_ref}
    end
  end

  defp cancel_refresh_timer(state, provider) do
    case state.refresh_timers[provider] do
      nil ->
        state

      timer_ref ->
        Process.cancel_timer(timer_ref)
        %{state | refresh_timers: Map.delete(state.refresh_timers, provider)}
    end
  end

  defp handle_refresh_with_retry(provider, state, attempt) do
    case do_refresh(provider, state) do
      {:ok, new_state} ->
        broadcast({:auth_refreshed, provider})
        {:noreply, new_state}

      {:error, reason} ->
        if attempt < @max_refresh_retries do
          next_attempt = attempt + 1
          delay = @initial_retry_delay_ms * Integer.pow(4, attempt)

          Process.send_after(self(), {:refresh_retry, provider, next_attempt}, delay)
          {:noreply, state}
        else
          broadcast({:auth_refresh_failed, provider, reason})
          {:noreply, state}
        end
    end
  end

  defp do_refresh(provider, state) do
    case :ets.lookup(@table, provider) do
      [{^provider, %{refresh_token: refresh_token}}] when is_binary(refresh_token) ->
        provider_mod = Loomkin.Auth.Provider.module_for(provider)

        case provider_mod.refresh_token(refresh_token) do
          {:ok, new_token_data} ->
            persist_and_cache(provider, new_token_data, state)

          {:error, reason} ->
            {:error, reason}
        end

      [{^provider, _}] ->
        {:error, :no_refresh_token}

      [] ->
        {:error, :no_token_found}
    end
  end

  defp token_expired?(%{expires_at: nil}), do: false

  defp token_expired?(%{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp broadcast({:auth_connected, provider}) do
    signal = Loomkin.Signals.System.AuthConnected.new!(%{provider: provider})
    Loomkin.Signals.publish(signal)
  end

  defp broadcast({:auth_disconnected, provider}) do
    signal = Loomkin.Signals.System.AuthDisconnected.new!(%{provider: provider})
    Loomkin.Signals.publish(signal)
  end

  defp broadcast({:auth_refreshed, provider}) do
    signal = Loomkin.Signals.System.AuthRefreshed.new!(%{provider: provider})
    Loomkin.Signals.publish(signal)
  end

  defp broadcast({:auth_refresh_failed, provider, _reason}) do
    signal = Loomkin.Signals.System.AuthRefreshFailed.new!(%{provider: provider})
    Loomkin.Signals.publish(signal)
  end
end
