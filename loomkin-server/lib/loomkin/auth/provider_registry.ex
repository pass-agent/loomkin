defmodule Loomkin.Auth.ProviderRegistry do
  @moduledoc """
  Single source of truth for OAuth-capable provider metadata.

  All provider-specific lists (auth modules, ReqLLM wrappers, env vars, OAuth
  prefixes, etc.) derive from the registry defined here. No other module should
  hardcode provider enumerations.

  ## Adding a new provider

  1. Create the auth adapter (`Loomkin.Auth.Providers.NewProvider`)
  2. Create the ReqLLM wrapper (`Loomkin.Providers.NewProviderOAuth`)
  3. Add an entry to `@providers` below
  4. Everything else propagates automatically.
  """

  @type flow_type :: :redirect | :paste_back

  @type provider_entry :: %{
          id: atom(),
          display_name: String.t(),
          auth_module: module(),
          reqllm_module: module(),
          oauth_prefix: String.t(),
          base_prefix: String.t(),
          env_var: String.t(),
          flow_type: flow_type()
        }

  # ── Registry ────────────────────────────────────────────────────────

  @providers [
    %{
      id: :anthropic,
      display_name: "Anthropic",
      auth_module: Loomkin.Auth.Providers.Anthropic,
      reqllm_module: Loomkin.Providers.AnthropicOAuth,
      oauth_prefix: "anthropic_oauth",
      base_prefix: "anthropic",
      env_var: "ANTHROPIC_API_KEY",
      flow_type: :paste_back
    },
    %{
      id: :google,
      display_name: "Google",
      auth_module: Loomkin.Auth.Providers.Google,
      reqllm_module: Loomkin.Providers.GoogleOAuth,
      oauth_prefix: "google_oauth",
      base_prefix: "google",
      env_var: "GOOGLE_API_KEY",
      flow_type: :redirect
    },
    %{
      id: :openai,
      display_name: "OpenAI",
      auth_module: Loomkin.Auth.Providers.OpenAI,
      reqllm_module: Loomkin.Providers.OpenAIOAuth,
      oauth_prefix: "openai_oauth",
      base_prefix: "openai",
      env_var: "OPENAI_API_KEY",
      flow_type: :redirect
    }
  ]

  # ── Lookup by ID ────────────────────────────────────────────────────

  @doc "Returns the full entry for a provider atom, or nil."
  @spec get(atom()) :: provider_entry() | nil
  def get(provider_id) when is_atom(provider_id) do
    Enum.find(@providers, &(&1.id == provider_id))
  end

  @doc "Returns the full entry for a provider atom. Raises on unknown provider."
  @spec get!(atom()) :: provider_entry()
  def get!(provider_id) when is_atom(provider_id) do
    get(provider_id) ||
      raise ArgumentError, "Unknown OAuth provider: #{inspect(provider_id)}"
  end

  # ── List helpers ────────────────────────────────────────────────────

  @doc "All registered provider entries."
  @spec all() :: [provider_entry()]
  def all, do: @providers

  @doc "All registered provider ID atoms."
  @spec provider_ids() :: [atom()]
  def provider_ids, do: Enum.map(@providers, & &1.id)

  @doc "Provider ID strings for route validation (e.g., `[\"anthropic\", \"google\"]`)."
  @spec provider_id_strings() :: [String.t()]
  def provider_id_strings, do: Enum.map(@providers, &Atom.to_string(&1.id))

  # ── Auth module registry (replaces Provider.@providers) ─────────────

  @doc """
  Map of provider atom → auth module.

  Replaces the hardcoded `@providers` map in `Loomkin.Auth.Provider`.
  """
  @spec auth_modules() :: %{atom() => module()}
  def auth_modules do
    Map.new(@providers, fn p -> {p.id, p.auth_module} end)
  end

  @doc "Returns the auth module for a provider atom, or raises."
  @spec auth_module_for!(atom()) :: module()
  def auth_module_for!(provider_id) do
    get!(provider_id).auth_module
  end

  # ── ReqLLM wrapper registry (replaces application.ex hardcoded call) ─

  @doc "All ReqLLM wrapper modules to register at startup."
  @spec reqllm_modules() :: [module()]
  def reqllm_modules, do: Enum.map(@providers, & &1.reqllm_module)

  # ── OAuth provider map (replaces LLM.@oauth_provider_map) ──────────

  @doc """
  Map of base provider string → OAuth provider string.

  E.g., `%{"anthropic" => "anthropic_oauth"}`
  """
  @spec oauth_provider_map() :: %{String.t() => String.t()}
  def oauth_provider_map do
    Map.new(@providers, fn p -> {p.base_prefix, p.oauth_prefix} end)
  end

  # ── OAuth-capable set (replaces Models.@oauth_capable_providers) ────

  @doc "MapSet of provider atoms that support OAuth."
  @spec oauth_capable_providers() :: MapSet.t(atom())
  def oauth_capable_providers do
    MapSet.new(@providers, & &1.id)
  end

  # ── Flow type helpers ──────────────────────────────────────────────

  @doc "Returns the OAuth flow type for a provider (`:redirect` or `:paste_back`)."
  @spec flow_type(atom()) :: flow_type()
  def flow_type(provider_id) do
    get!(provider_id).flow_type
  end

  # ── Pricing / model prefix helpers ─────────────────────────────────

  @doc """
  Returns `true` if the model string uses an OAuth provider prefix.

  E.g., `"anthropic_oauth:claude-sonnet-4-6"` → `true`
  """
  @spec oauth_prefix?(String.t()) :: boolean()
  def oauth_prefix?(model) when is_binary(model) do
    Enum.any?(@providers, fn p ->
      String.starts_with?(model, p.oauth_prefix <> ":")
    end)
  end

  @doc """
  Returns `true` if the model string uses a base prefix that has an
  OAuth-capable provider.

  E.g., `"anthropic:claude-sonnet-4-6"` → `true`
  """
  @spec oauth_base_prefix?(String.t()) :: boolean()
  def oauth_base_prefix?(model) when is_binary(model) do
    Enum.any?(@providers, fn p ->
      String.starts_with?(model, p.base_prefix <> ":")
    end)
  end

  @doc """
  Returns the env var name for a given provider atom, or nil if not registered.
  """
  @spec env_var(atom()) :: String.t() | nil
  def env_var(provider_id) do
    case get(provider_id) do
      nil -> nil
      entry -> entry.env_var
    end
  end

  @doc """
  Returns the base prefix string for a given provider atom.

  Used for extracting the provider string from a model spec to check
  OAuth status.
  """
  @spec base_prefix(atom()) :: String.t()
  def base_prefix(provider_id) do
    get!(provider_id).base_prefix
  end
end
