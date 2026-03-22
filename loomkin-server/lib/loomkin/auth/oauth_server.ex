defmodule Loomkin.Auth.OAuthServer do
  @moduledoc """
  Manages in-flight OAuth authorization flows.

  When a user clicks "Connect" for a provider in the UI, this GenServer:

  1. Generates a PKCE code verifier + state token
  2. Stores them keyed by state (for CSRF validation on callback)
  3. Returns the authorization URL and flow type to the caller
  4. On callback (redirect) or paste submission (paste-back), validates state,
     exchanges the code for tokens, and delegates to `TokenStore` for persistence

  ## Flow types

  - `:redirect` — Standard OAuth: browser redirects back to localhost callback
  - `:paste_back` — Provider redirects to their own domain; user pastes `code#state`
    string back into Loomkin (used by Anthropic, whose redirect URI is on their domain)

  Flows expire after a configurable timeout (default 10 minutes) to
  prevent stale state accumulation.
  """

  use GenServer

  alias Loomkin.Auth.Provider
  alias Loomkin.Auth.ProviderRegistry
  alias Loomkin.Auth.TokenStore

  @flow_timeout_ms :timer.minutes(10)

  @type flow_type :: :redirect | :paste_back

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initiate an OAuth flow for the given provider.

  Returns `{:ok, authorize_url, flow_type}` where `flow_type` is
  `:redirect` or `:paste_back`, indicating how the UI should handle
  the authorization URL.
  """
  @spec start_flow(atom(), String.t()) :: {:ok, String.t(), flow_type()} | {:error, term()}
  def start_flow(provider, redirect_uri) do
    GenServer.call(__MODULE__, {:start_flow, provider, redirect_uri})
  end

  @doc """
  Handle a standard OAuth redirect callback. Validates state, exchanges
  code for tokens, and stores them.

  Returns `:ok` on success or `{:error, reason}`.
  """
  @spec handle_callback(String.t(), String.t()) :: :ok | {:error, term()}
  def handle_callback(state, code) do
    GenServer.call(__MODULE__, {:handle_callback, state, code}, 30_000)
  end

  @doc """
  Handle a paste-back submission for providers that don't redirect to
  localhost (e.g., Anthropic).

  The user pastes the `code#state` string from the provider's redirect page.
  This function looks up the active flow for the given provider, parses/validates
  the pasted string, exchanges the code for tokens, and stores them.

  Returns `:ok` on success or `{:error, reason}`.
  """
  @spec handle_paste(atom(), String.t()) :: :ok | {:error, term()}
  def handle_paste(provider, code_with_state) do
    GenServer.call(__MODULE__, {:handle_paste, provider, code_with_state}, 30_000)
  end

  @doc """
  Check if there's an active flow for a provider (useful for UI status).
  """
  @spec flow_active?(atom()) :: boolean()
  def flow_active?(provider) do
    GenServer.call(__MODULE__, {:flow_active?, provider})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Create ETS table for Google OAuth session params (owned by this GenServer)
    :ets.new(:loomkin_google_oauth_sessions, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    # flows: %{state_string => %{provider, code_verifier, redirect_uri, state_token, flow_type, timer_ref, started_at}}
    {:ok, %{flows: %{}}}
  end

  @impl true
  def handle_call({:start_flow, provider, redirect_uri}, _from, state) do
    provider_mod = Provider.module_for(provider)
    flow_type = ProviderRegistry.flow_type(provider)

    code_verifier = Provider.generate_code_verifier()
    state_token = Provider.generate_state()

    case provider_mod.build_authorize_url(%{
           state: state_token,
           code_verifier: code_verifier,
           redirect_uri: redirect_uri
         }) do
      {:ok, authorize_url} ->
        # Schedule expiry cleanup
        timer_ref = Process.send_after(self(), {:flow_expired, state_token}, @flow_timeout_ms)

        flow = %{
          provider: provider,
          code_verifier: code_verifier,
          redirect_uri: redirect_uri,
          state_token: state_token,
          flow_type: flow_type,
          timer_ref: timer_ref,
          started_at: System.monotonic_time(:millisecond)
        }

        new_state = put_in(state.flows[state_token], flow)
        {:reply, {:ok, authorize_url, flow_type}, new_state}

      {:error, reason} ->
        {:reply, {:error, {:authorize_url_failed, reason}}, state}
    end
  end

  @impl true
  def handle_call({:handle_callback, state_token, code}, _from, state) do
    case Map.pop(state.flows, state_token) do
      {nil, _} ->
        {:reply, {:error, :invalid_state}, state}

      {flow, remaining_flows} ->
        result = exchange_and_store(flow, code)
        {:reply, result, %{state | flows: remaining_flows}}
    end
  end

  @impl true
  def handle_call({:handle_paste, provider, code_with_state}, _from, state) do
    # Find the active flow for this provider
    case find_flow_by_provider(state.flows, provider) do
      nil ->
        {:reply, {:error, :no_active_flow}, state}

      {state_token, flow} ->
        # Anthropic returns "code#state" — parse and validate
        provider_mod = Provider.module_for(provider)

        parse_result =
          if function_exported?(provider_mod, :parse_code_and_state, 2) do
            provider_mod.parse_code_and_state(code_with_state, flow.state_token)
          else
            # Fallback: treat the whole string as the code
            {:ok, code_with_state, flow.state_token}
          end

        case parse_result do
          {:ok, code, _validated_state} ->
            remaining_flows = Map.delete(state.flows, state_token)
            result = exchange_and_store(flow, code)
            {:reply, result, %{state | flows: remaining_flows}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:flow_active?, provider}, _from, state) do
    active =
      state.flows
      |> Map.values()
      |> Enum.any?(fn flow -> flow.provider == provider end)

    {:reply, active, state}
  end

  @impl true
  def handle_info({:flow_expired, state_token}, state) do
    case Map.pop(state.flows, state_token) do
      {nil, _} ->
        {:noreply, state}

      {_flow, remaining_flows} ->
        # Piggyback: clean up stale Google OAuth session entries
        cleanup_stale_sessions()

        {:noreply, %{state | flows: remaining_flows}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private helpers ────────────────────────────────────────────────

  # Exchange code for tokens and store them. Shared by both callback and paste-back flows.
  defp exchange_and_store(flow, code) do
    # Cancel the expiry timer
    Process.cancel_timer(flow.timer_ref)

    provider_mod = Provider.module_for(flow.provider)

    result =
      provider_mod.exchange_code(%{
        code: code,
        code_verifier: flow.code_verifier,
        redirect_uri: flow.redirect_uri,
        state: flow.state_token
      })

    case result do
      {:ok, token_data} ->
        case TokenStore.store_tokens(flow.provider, token_data) do
          :ok ->
            :ok

          {:error, _reason} ->
            {:error, :token_store_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Find the first active flow for a given provider atom.
  # Returns `{state_token, flow}` or `nil`.
  defp find_flow_by_provider(flows, provider) do
    Enum.find_value(flows, fn {state_token, flow} ->
      if flow.provider == provider, do: {state_token, flow}
    end)
  end

  # Clean up stale Google OAuth session entries older than the flow timeout.
  defp cleanup_stale_sessions do
    table = :loomkin_google_oauth_sessions
    cutoff = System.monotonic_time(:second) - div(@flow_timeout_ms, 1000)

    :ets.tab2list(table)
    |> Enum.each(fn {key, _session_params, inserted_at} ->
      if inserted_at < cutoff, do: :ets.delete(table, key)
    end)
  rescue
    ArgumentError -> :ok
  end
end
