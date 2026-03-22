defmodule Loomkin.LLM do
  @moduledoc """
  Thin wrapper around ReqLLM that transparently upgrades API-key providers
  to their OAuth equivalents when the user has an active OAuth connection.

  All LLM calls in Loomkin should go through this module instead of calling
  `ReqLLM.stream_text/3` or `ReqLLM.generate_text/3` directly.

  ## How it works

  1. Accepts the same arguments as `ReqLLM.stream_text/3` / `ReqLLM.generate_text/3`.
  2. Inspects the model spec (e.g., `"anthropic:claude-sonnet-4-6"`).
  3. If the provider has an active OAuth token in `TokenStore`, resolves the
     model via LLMDB using the canonical provider name, then routes through
     the custom OAuth provider module (e.g., `AnthropicOAuth`) which handles
     Bearer auth. This avoids LLMDB failing on unknown provider names like
     `"anthropic_oauth"`.
  4. If no OAuth token is available, passes through to ReqLLM unchanged.

  This keeps call sites completely unaware of the auth mechanism.
  """

  alias Loomkin.Auth.ProviderRegistry
  alias Loomkin.Auth.TokenStore

  @doc """
  Stream text from an LLM provider, transparently using OAuth when available.

  Accepts the same arguments as `ReqLLM.stream_text/3`.
  """
  @spec stream_text(String.t() | term(), term(), keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream_text(model_spec, messages, opts \\ []) do
    case maybe_resolve_local(model_spec) do
      {:local, model, provider_module} ->
        with {:ok, context} <- ReqLLM.Context.normalize(messages, opts) do
          ReqLLM.Streaming.start_stream(provider_module, model, context, opts)
        end

      :not_local ->
        case maybe_resolve_oauth(model_spec) do
          {:oauth, model, provider_module} ->
            with {:ok, context} <- ReqLLM.Context.normalize(messages, opts) do
              ReqLLM.Streaming.start_stream(provider_module, model, context, opts)
            end

          :passthrough ->
            ReqLLM.stream_text(model_spec, messages, opts)
        end
    end
  end

  @doc """
  Generate text from an LLM provider, transparently using OAuth when available.

  Accepts the same arguments as `ReqLLM.generate_text/3`.
  """
  @spec generate_text(String.t() | term(), term(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def generate_text(model_spec, messages, opts \\ []) do
    case maybe_resolve_local(model_spec) do
      {:local, model, provider_module} ->
        with {:ok, request} <- provider_module.prepare_request(:chat, model, messages, opts),
             {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
               Req.request(request) do
          {:ok, body}
        else
          {:ok, %Req.Response{status: status, body: body}} ->
            {:error,
             ReqLLM.Error.API.Request.exception(
               reason: "HTTP #{status}: Request failed",
               status: status,
               response_body: body
             )}

          {:error, error} ->
            {:error, error}
        end

      :not_local ->
        case maybe_resolve_oauth(model_spec) do
          {:oauth, model, provider_module} ->
            with {:ok, request} <-
                   provider_module.prepare_request(:chat, model, messages, opts),
                 {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
                   Req.request(request) do
              {:ok, body}
            else
              {:ok, %Req.Response{status: status, body: body}} ->
                {:error,
                 ReqLLM.Error.API.Request.exception(
                   reason: "HTTP #{status}: Request failed",
                   status: status,
                   response_body: body
                 )}

              {:error, error} ->
                {:error, error}
            end

          :passthrough ->
            ReqLLM.generate_text(model_spec, messages, opts)
        end
    end
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

  # Local providers (Ollama, etc.) bypass LLMDB entirely since their models
  # aren't cataloged. We intercept these before OAuth resolution.
  @spec maybe_resolve_local(term()) :: {:local, struct(), module()} | :not_local
  defp maybe_resolve_local(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      ["ollama", model_id] ->
        model = Loomkin.Providers.Ollama.build_model(model_id)

        case ReqLLM.provider(:ollama) do
          {:ok, provider_module} -> {:local, model, provider_module}
          _ -> :not_local
        end

      _ ->
        :not_local
    end
  end

  defp maybe_resolve_local(_), do: :not_local

  # For OAuth providers, we resolve the model via LLMDB using the canonical
  # provider name (e.g. "anthropic") but route through the custom OAuth provider
  # module (e.g. AnthropicOAuth). This avoids LLMDB failing on unknown
  # provider names like "anthropic_oauth".
  @spec maybe_resolve_oauth(term()) :: {:oauth, struct(), module()} | :passthrough
  defp maybe_resolve_oauth(model_spec) when is_binary(model_spec) do
    oauth_map = ProviderRegistry.oauth_provider_map()

    case String.split(model_spec, ":", parts: 2) do
      [provider, _model_id] ->
        case Map.get(oauth_map, provider) do
          nil ->
            :passthrough

          oauth_provider ->
            provider_atom = String.to_existing_atom(provider)

            if TokenStore.get_access_token(provider_atom) != nil do
              oauth_atom = String.to_existing_atom(oauth_provider)

              with {:ok, model} <- ReqLLM.model(model_spec),
                   {:ok, provider_module} <- ReqLLM.provider(oauth_atom) do
                {:oauth, model, provider_module}
              else
                _ -> :passthrough
              end
            else
              :passthrough
            end
        end

      _ ->
        :passthrough
    end
  rescue
    _ -> :passthrough
  end

  defp maybe_resolve_oauth(_model_spec), do: :passthrough
end
