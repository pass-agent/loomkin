defmodule Loomkin.Models do
  @moduledoc """
  Dynamic model discovery based on configured API keys, OAuth connections,
  and the LLMDB catalog.

  Checks which provider API keys are present in the environment and which
  providers have active OAuth connections, then queries LLMDB for
  chat-capable models from those providers.
  Users can also type any `provider:model` string directly.
  """

  # Provider atom → {display name, env var name}
  @providers %{
    anthropic: {"Anthropic", "ANTHROPIC_API_KEY"},
    openai: {"OpenAI", "OPENAI_API_KEY"},
    google: {"Google", "GOOGLE_API_KEY"},
    zai: {"Z.AI", "ZAI_API_KEY"},
    xai: {"xAI", "XAI_API_KEY"},
    groq: {"Groq", "GROQ_API_KEY"},
    deepseek: {"DeepSeek", "DEEPSEEK_API_KEY"},
    openrouter: {"OpenRouter", "OPENROUTER_API_KEY"},
    mistral: {"Mistral", "MISTRAL_API_KEY"},
    cerebras: {"Cerebras", "CEREBRAS_API_KEY"},
    togetherai: {"Together AI", "TOGETHER_API_KEY"},
    fireworks_ai: {"Fireworks AI", "FIREWORKS_API_KEY"},
    cohere: {"Cohere", "COHERE_API_KEY"},
    perplexity: {"Perplexity", "PERPLEXITY_API_KEY"},
    nvidia: {"NVIDIA", "NVIDIA_API_KEY"},
    azure: {"Azure", "AZURE_API_KEY"},
    google_vertex: {"Google Vertex AI", "GOOGLE_APPLICATION_CREDENTIALS"}
  }

  # Providers that support OAuth authentication.
  # Derived from the central ProviderRegistry.
  defp oauth_capable_providers do
    Loomkin.Auth.ProviderRegistry.oauth_capable_providers()
  end

  @doc """
  Returns `[{provider_name, [{model_label, "provider:model_id"}, ...]}]`
  for all providers that have an API key set or an active OAuth connection.
  Includes local providers (Ollama) when available.
  """
  def available_models do
    cloud_models =
      @providers
      |> Enum.filter(fn {provider, {_name, _env_var}} ->
        provider_available?(provider)
      end)
      |> Enum.map(fn {provider, {display_name, _env_var}} ->
        models = fetch_provider_models(provider)
        {display_name, models}
      end)
      |> Enum.reject(fn {_name, models} -> models == [] end)

    local_models = fetch_ollama_models()

    endpoint_models =
      Loomkin.Providers.OpenAICompatibleProvider.get_all_endpoints()
      |> Enum.flat_map(&fetch_endpoint_models/1)

    (endpoint_models ++ local_models ++ cloud_models)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  @doc "Returns the list of all known provider atoms and their env var names."
  def known_providers, do: @providers

  @doc """
  Returns the authentication status for a given provider atom.

  Returns:
  - `{:set, env_var_name}` if the API key is present and non-empty
  - `{:oauth, :connected}` if no API key but an active OAuth token exists
  - `{:oauth, :disconnected}` if the provider supports OAuth but no token is active
  - `{:missing, env_var_name}` if no API key and provider doesn't support OAuth
  """
  def api_key_status(provider_atom) do
    case Map.get(@providers, provider_atom) do
      {_name, env_var} ->
        key = System.get_env(env_var)

        cond do
          key != nil and key != "" ->
            {:set, env_var}

          oauth_connected?(provider_atom) ->
            {:oauth, :connected}

          oauth_capable?(provider_atom) ->
            {:oauth, :disconnected}

          true ->
            {:missing, env_var}
        end

      nil when provider_atom == :ollama ->
        if Loomkin.Providers.Ollama.available?(), do: :local, else: :local_offline

      nil ->
        {:missing, "UNKNOWN_API_KEY"}
    end
  end

  @doc "Returns true if the provider supports OAuth authentication."
  def oauth_capable?(provider_atom) do
    MapSet.member?(oauth_capable_providers(), provider_atom)
  end

  @doc "Returns true if the provider has an active OAuth connection."
  def oauth_connected?(provider_atom) do
    Loomkin.LLM.oauth_active?(Atom.to_string(provider_atom))
  rescue
    _ -> false
  end

  @doc "Returns the env var name for a given provider atom."
  def provider_api_key_name(provider_atom) do
    case Map.get(@providers, provider_atom) do
      {_name, env_var} -> env_var
      nil -> nil
    end
  end

  @doc """
  Like `available_models/0` but includes context window info.

  Returns `[{provider_name, [{label, "provider:model_id", context_label}, ...]}]`
  """
  def available_models_enriched do
    cloud_models =
      @providers
      |> Enum.filter(fn {provider, {_name, _env_var}} ->
        provider_available?(provider)
      end)
      |> Enum.map(fn {provider, {display_name, _env_var}} ->
        models = fetch_provider_models_enriched(provider)
        {display_name, models}
      end)
      |> Enum.reject(fn {_name, models} -> models == [] end)

    local_models = fetch_ollama_models_enriched()

    (local_models ++ cloud_models)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  @doc """
  Returns ALL providers with their auth status and models (including providers without keys).

  Returns `[{provider_atom, display_name, key_status, [{label, value, ctx_label}]}]`
  sorted with keyed/OAuth-connected providers first, then alphabetical.
  """
  def all_providers_enriched do
    cloud_providers =
      @providers
      |> Enum.map(fn {provider, {display_name, _env_var}} ->
        status = api_key_status(provider)

        models =
          case status do
            {:set, _} -> fetch_provider_models_enriched(provider)
            {:oauth, :connected} -> fetch_provider_models_enriched(provider)
            _ -> []
          end

        {provider, display_name, status, models}
      end)

    ollama_entry = build_ollama_provider_entry()

    endpoint_entries = build_endpoint_provider_entries()

    (endpoint_entries ++ ollama_entry ++ cloud_providers)
    |> Enum.sort_by(fn {_p, name, status, _m} ->
      priority =
        case status do
          {:set, _} -> 0
          {:oauth, :connected} -> 0
          :local -> 0
          {:oauth, :disconnected} -> 1
          {:missing, _} -> 2
          :local_offline -> 2
        end

      {priority, name}
    end)
  end

  defp provider_available?(provider) do
    case api_key_status(provider) do
      {:set, _} -> true
      {:oauth, :connected} -> true
      _ -> false
    end
  end

  defp fetch_provider_models(provider) do
    LLMDB.models(provider)
    |> Enum.filter(&chat_capable?/1)
    |> Enum.reject(fn m -> m.deprecated || m.retired end)
    |> Enum.sort_by(&model_sort_key/1, :desc)
    |> Enum.map(fn m ->
      {m.name || m.id, "#{provider}:#{m.id}"}
    end)
  rescue
    _ -> []
  end

  defp fetch_provider_models_enriched(provider) do
    LLMDB.models(provider)
    |> Enum.filter(&chat_capable?/1)
    |> Enum.reject(fn m -> m.deprecated || m.retired end)
    |> Enum.sort_by(&model_sort_key/1, :desc)
    |> Enum.map(fn m ->
      ctx_label = format_context_window(m)
      {m.name || m.id, "#{provider}:#{m.id}", ctx_label}
    end)
  rescue
    _ -> []
  end

  defp chat_capable?(%{capabilities: %{chat: true}}), do: true
  defp chat_capable?(_), do: false

  defp model_sort_key(model) do
    # Sort by release date descending (newest first), then name
    date = model.release_date || "0000-00-00"
    {date, model.id}
  end

  defp format_context_window(%{limits: %{context: ctx}})
       when is_integer(ctx) and ctx >= 1_000_000 do
    "#{div(ctx, 1_000_000)}M ctx"
  end

  defp format_context_window(%{limits: %{context: ctx}}) when is_integer(ctx) and ctx >= 1_000 do
    "#{div(ctx, 1_000)}K ctx"
  end

  defp format_context_window(_), do: nil

  # ── Ollama (local) helpers ──────────────────────────────────────────

  defp fetch_ollama_models() do
    case Loomkin.Providers.Ollama.list_models() do
      {:ok, models} ->
        entries =
          models
          |> Enum.map(fn m ->
            name = m["name"] || m["model"]
            {name, "ollama:#{name}"}
          end)

        if entries == [], do: [], else: [{"Ollama (Local)", entries}]

      _ ->
        []
    end
  end

  defp fetch_ollama_models_enriched do
    case Loomkin.Providers.Ollama.list_models() do
      {:ok, models} ->
        entries =
          models
          |> Enum.map(fn m ->
            name = m["name"] || m["model"]
            size = format_ollama_size(m["size"])
            {name, "ollama:#{name}", size}
          end)

        if entries == [], do: [], else: [{"Ollama (Local)", entries}]

      _ ->
        []
    end
  end

  defp build_ollama_provider_entry do
    case Loomkin.Providers.Ollama.list_models() do
      {:ok, models} ->
        entries =
          Enum.map(models, fn m ->
            name = m["name"] || m["model"]
            size = format_ollama_size(m["size"])
            {name, "ollama:#{name}", size}
          end)

        [{:ollama, "Ollama (Local)", :local, entries}]

      _ ->
        [{:ollama, "Ollama (Local)", :local_offline, []}]
    end
  end

  defp build_endpoint_provider_entries do
    Loomkin.Providers.OpenAICompatibleProvider.get_all_endpoints()
    |> Enum.reject(&(&1 == "ollama"))
    |> Enum.flat_map(fn provider ->
      base_url =
        case Loomkin.Config.get_provider_endpoint(provider) do
          %{url: url} when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
          %{"url" => url} when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
          _ -> nil
        end

      if base_url do
        url = "#{base_url}/models"

        case Req.get(url, receive_timeout: 5_000, retry: false) do
          {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
            entries =
              data
              |> Enum.map(fn m ->
                name = m["id"] || m["name"]
                {name, "#{provider}:#{name}", "endpoint"}
              end)

            display_name = String.capitalize(to_string(provider))
            [{String.to_atom(provider), "#{display_name} (Endpoint)", :local, entries}]

          _ ->
            display_name = String.capitalize(to_string(provider))
            [{String.to_atom(provider), "#{display_name} (Endpoint)", :local_offline, []}]
        end
      else
        []
      end
    end)
  end

  defp format_ollama_size(nil), do: "local"

  defp format_ollama_size(bytes) when is_integer(bytes) and bytes >= 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 1)}GB"
  end

  defp format_ollama_size(bytes) when is_integer(bytes) and bytes >= 1_000_000 do
    "#{div(bytes, 1_000_000)}MB"
  end

  defp format_ollama_size(_), do: "local"

  # ── Endpoint helpers ────────────────────────────────────────────────

  defp fetch_endpoint_models(provider) do
    case provider do
      "ollama" -> fetch_ollama_models()
      _ -> fetch_openai_compat_models(provider)
    end
  end

  defp fetch_openai_compat_models(provider) do
    base_url =
      case Loomkin.Config.get_provider_endpoint(provider) do
        %{url: url} when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
        %{"url" => url} when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
        _ -> nil
      end

    if base_url do
      url = "#{base_url}/models"

      case Req.get(url, receive_timeout: 5_000, retry: false) do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
          entries =
            data
            |> Enum.map(fn m ->
              name = m["id"] || m["name"]
              {name, "#{provider}:#{name}"}
            end)

          if entries == [],
            do: [],
            else: [{"#{String.capitalize(to_string(provider))}", entries}]

        _ ->
          []
      end
    else
      []
    end
  end
end
