defmodule Loomkin.LLM do
  @moduledoc """
  Thin wrapper around ReqLLM that transparently upgrades API-key providers
  to their OAuth equivalents when the user has an active OAuth connection.

  All LLM calls in Loomkin should go through this module instead of calling
  `ReqLLM.stream_text/3` or `ReqLLM.generate_text/3` directly.

  ## How it works

  1. Accepts the same arguments as `ReqLLM.stream_text/3` / `ReqLLM.generate_text/3`.
  2. Inspects the model spec (e.g., `"anthropic:claude-sonnet-4-6"`).
  3. If the provider has an active OAuth token in `TokenStore`, rewrites the
     model spec to its OAuth variant (e.g., `"anthropic_oauth:claude-sonnet-4-6"`).
     The custom OAuth provider then handles Bearer auth automatically.
  4. If no OAuth token is available, passes through unchanged — the stock
     provider resolves the API key via its normal chain.

  This keeps call sites completely unaware of the auth mechanism.
  """

  require Logger

  alias Loomkin.Auth.ProviderRegistry
  alias Loomkin.Auth.TokenStore

  @doc """
  Stream text from an LLM provider, transparently using OAuth when available.

  Accepts the same arguments as `ReqLLM.stream_text/3`.
  """
  @spec stream_text(String.t() | term(), term(), keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream_text(model_spec, messages, opts \\ []) do
    model_spec = maybe_upgrade_to_oauth(model_spec)
    ReqLLM.stream_text(model_spec, messages, opts)
  end

  @doc """
  Generate text from an LLM provider, transparently using OAuth when available.

  Accepts the same arguments as `ReqLLM.generate_text/3`.
  """
  @spec generate_text(String.t() | term(), term(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def generate_text(model_spec, messages, opts \\ []) do
    model_spec = maybe_upgrade_to_oauth(model_spec)
    ReqLLM.generate_text(model_spec, messages, opts)
  end

  @doc """
  Check whether a given provider string has an active OAuth connection.

  Returns `true` if the provider has a valid (non-expired) OAuth token
  stored in the TokenStore.

  ## Examples

      iex> Loomkin.LLM.oauth_active?("anthropic")
      true

      iex> Loomkin.LLM.oauth_active?("openai")
      false
  """
  @spec oauth_active?(String.t()) :: boolean()
  def oauth_active?(provider) when is_binary(provider) do
    case Map.get(ProviderRegistry.oauth_provider_map(), provider) do
      nil ->
        false

      _oauth_provider ->
        provider_atom = String.to_existing_atom(provider)
        TokenStore.get_access_token(provider_atom) != nil
    end
  rescue
    # TokenStore not started, atom doesn't exist, etc.
    _ -> false
  end

  @doc """
  Returns the provider map of base providers to their OAuth variants.
  Useful for UI components that need to know which providers support OAuth.
  """
  @spec oauth_providers() :: %{String.t() => String.t()}
  def oauth_providers, do: ProviderRegistry.oauth_provider_map()

  # ── Internal ─────────────────────────────────────────────────────────

  defp maybe_upgrade_to_oauth(model_spec) when is_binary(model_spec) do
    oauth_map = ProviderRegistry.oauth_provider_map()

    case String.split(model_spec, ":", parts: 2) do
      [provider, model_id] ->
        case Map.get(oauth_map, provider) do
          nil ->
            # No OAuth variant for this provider
            model_spec

          oauth_provider ->
            provider_atom = String.to_existing_atom(provider)

            if TokenStore.get_access_token(provider_atom) != nil do
              Logger.debug("Upgrading #{provider}:#{model_id} to OAuth provider")
              "#{oauth_provider}:#{model_id}"
            else
              model_spec
            end
        end

      _ ->
        # Not a "provider:model" string, pass through
        model_spec
    end
  rescue
    # If TokenStore isn't running or atom doesn't exist, fall through
    _ -> model_spec
  end

  # Non-string model specs (structs, tuples) pass through unchanged.
  # OAuth upgrade only works with the standard "provider:model" string format.
  defp maybe_upgrade_to_oauth(model_spec), do: model_spec
end
