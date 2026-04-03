defmodule Loomkin.Providers.OpenAICompatibleProvider do
  @moduledoc """
  Manages dynamic OpenAI-compatible endpoint providers.

  Reads `[provider.endpoints]` from config and creates custom provider modules
  on-the-fly for each configured endpoint.
  """

  use GenServer

  @registry :endpoint_provider_registry

  @doc """
  Get the provider module for a given endpoint provider name.
  Returns `nil` if no endpoint is configured for this provider.
  """
  @spec get_endpoint_provider(String.t()) :: module() | nil
  def get_endpoint_provider(provider_name) when is_binary(provider_name) do
    with {:ok, mod_name} <- lookup_cached_provider(provider_name) do
      if Code.ensure_loaded?(mod_name), do: mod_name, else: nil
    else
      _ -> nil
    end
  end

  @doc """
  Register a new endpoint provider dynamically.
  Returns the provider module (existing or newly created).
  """
  @spec register_endpoint(String.t(), String.t(), String.t() | nil) :: module()
  def register_endpoint(provider_name, url, auth_key)
      when is_binary(provider_name) and is_binary(url) do
    provider_name
    |> String.trim()
    |> create_provider_module(url, auth_key)
  end

  @doc """
  Get all configured endpoint provider names with valid URLs.
  """
  @spec get_all_endpoints() :: [String.t()]
  def get_all_endpoints do
    case Loomkin.Config.get(:provider, :endpoints) do
      %{} = eps ->
        eps
        |> Enum.map(fn
          {name, %{url: url}} when is_binary(url) and url != "" ->
            if is_atom(name), do: Atom.to_string(name), else: name

          {name, config} when is_map(config) ->
            # TOML-parsed configs may have string keys
            url = config["url"] || Map.get(config, :url)

            if is_binary(url) and url != "",
              do: if(is_atom(name), do: Atom.to_string(name), else: name),
              else: nil

          _ ->
            nil
        end)
        |> Enum.filter(& &1)

      _ ->
        []
    end
  end

  @doc """
  Build a standard OpenAI-compat Req request for a chat completion.
  Used by both dynamically generated providers and static ones like Ollama.
  """
  def build_chat_request(model, base_url, opts) do
    opts_with_context = opts
    http_opts = Keyword.get(opts, :req_http_options, [])
    timeout = Keyword.get(opts, :receive_timeout, 120_000)

    req_keys = [
      :context,
      :operation,
      :model,
      :provider_options,
      :api_key,
      :tools,
      :tool_choice,
      :stream,
      :temperature,
      :max_tokens,
      :n,
      :fixture,
      :on_unsupported,
      :receive_timeout,
      :req_http_options,
      :base_url,
      :api_mod
    ]

    Req.new(
      [
        url: "/chat/completions",
        method: :post,
        receive_timeout: timeout,
        pool_timeout: timeout,
        connect_options: [timeout: timeout]
      ] ++ http_opts
    )
    |> Req.Request.register_options(req_keys)
    |> Req.Request.merge_options(
      Keyword.take(opts_with_context, req_keys) ++
        [
          model: model.provider_model_id || model.id,
          base_url: base_url,
          api_mod: ReqLLM.Providers.OpenAI.ChatAPI
        ]
    )
  end

  @doc """
  Attach standard OpenAI-compat request/response steps to a Req request.
  """
  def attach_openai_compat(request, model, user_opts) do
    extra_option_keys = [
      :model,
      :temperature,
      :max_tokens,
      :api_key,
      :tools,
      :tool_choice,
      :stream,
      :provider_options,
      :fixture,
      :on_unsupported,
      :n,
      :receive_timeout,
      :req_http_options,
      :base_url,
      :context,
      :api_mod
    ]

    request
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.merge_options(user_opts)
    |> Req.Request.put_private(:req_llm_model, model)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(
      llm_encode_body: &ReqLLM.Providers.OpenAI.ChatAPI.encode_body/1
    )
    |> Req.Request.append_response_steps(
      llm_decode_response: &ReqLLM.Providers.OpenAI.ChatAPI.decode_response/1
    )
  end

  @doc """
  Build a Finch streaming request for an OpenAI-compat endpoint.
  """
  def build_stream_request(model, context, base_url, headers, opts) do
    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.put(:stream, true)
      |> Keyword.put(:base_url, base_url)

    body = build_stream_body(model, context, cleaned_opts)
    url = "#{base_url}/chat/completions"

    Finch.build(:post, url, headers, Jason.encode!(body))
  end

  @doc """
  Build the JSON body for a streaming chat completion request.
  """
  def build_stream_body(model, context, opts) do
    chat_api = ReqLLM.Providers.OpenAI.ChatAPI

    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(
        :options,
        Map.new(
          [
            model: model.provider_model_id || model.id,
            context: context,
            stream: true,
            api_mod: chat_api
          ] ++ Keyword.delete(opts, :finch_name)
        )
      )

    encoded = chat_api.encode_body(temp_request)

    case Jason.decode(encoded.body) do
      {:ok, body_map} -> Map.put(body_map, "stream", true)
      _ -> %{"model" => model.id, "stream" => true}
    end
  end

  defp lookup_cached_provider(provider_name) do
    Registry.lookup(@registry, provider_name)
    |> case do
      [{_pid, mod_name}] -> {:ok, mod_name}
      [] -> {:error, :not_found}
    end
  end

  defp create_provider_module(provider_name, url, auth_key) do
    mod_name = generate_module_name(provider_name)

    with {:ok, existing} <- lookup_cached_provider(provider_name) do
      if Code.ensure_loaded?(existing),
        do: existing,
        else: build_provider_module(provider_name, mod_name, url, auth_key)
    else
      {:error, :not_found} ->
        build_provider_module(provider_name, mod_name, url, auth_key)
    end
  end

  defp generate_module_name(provider_name) do
    provider_name
    |> String.capitalize()
    |> Module.concat(Endpoint)
  end

  defp build_provider_module(provider_name, mod_name, url, auth_key) do
    contents =
      quote do
        use ReqLLM.Provider,
          id: unquote(String.to_atom(provider_name)),
          default_base_url: unquote(url)

        alias Loomkin.Providers.OpenAICompatibleProvider

        @provider_name unquote(provider_name)
        @provider_url unquote(url)
        @provider_auth_key unquote(auth_key)

        def register!, do: ReqLLM.Providers.register!(__MODULE__)

        def prepare_request(:chat, model_spec, prompt, opts) do
          model = resolve_model(model_spec)

          with {:ok, context} <- ReqLLM.Context.normalize(prompt, opts) do
            opts_with_context = Keyword.put(opts, :context, context)

            request =
              OpenAICompatibleProvider.build_chat_request(model, @provider_url, opts_with_context)
              |> attach(model, opts_with_context)

            {:ok, request}
          end
        end

        def prepare_request(operation, _model_spec, _input, _opts) do
          {:error,
           ReqLLM.Error.Invalid.Parameter.exception(
             parameter:
               "operation: #{inspect(operation)} not supported by #{@provider_name} provider"
           )}
        end

        def attach(request, model, user_opts) do
          request
          |> maybe_add_auth()
          |> OpenAICompatibleProvider.attach_openai_compat(model, user_opts)
        end

        def encode_body(request), do: ReqLLM.Providers.OpenAI.ChatAPI.encode_body(request)

        def decode_response(pair), do: ReqLLM.Providers.OpenAI.ChatAPI.decode_response(pair)

        def extract_usage(body, model), do: ReqLLM.Providers.OpenAI.extract_usage(body, model)

        def attach_stream(model, context, opts, _finch_name) do
          headers = [
            {"Accept", "text/event-stream"},
            {"Content-Type", "application/json"}
          ]

          headers =
            case @provider_auth_key do
              key when is_binary(key) and key != "" ->
                [{"Authorization", "Bearer " <> key} | headers]

              _ ->
                headers
            end

          {:ok,
           OpenAICompatibleProvider.build_stream_request(
             model,
             context,
             @provider_url,
             headers,
             opts
           )}
        rescue
          error ->
            {:error,
             ReqLLM.Error.API.Request.exception(
               reason: "Failed to build #{@provider_name} stream request: #{inspect(error)}"
             )}
        end

        # WORKAROUND: req_llm's default_decode_stream_event silently drops SSE events
        # containing {"error": {...}} payloads (returns []). This intercepts error events
        # from OpenAI-compatible endpoints and raises so call_llm's try/rescue can
        # surface the error to the UI.
        def decode_stream_event(%{data: %{"error" => error_data}} = _event, _model)
            when is_map(error_data) do
          message =
            Map.get(error_data, "message", "Unknown streaming error from #{@provider_name}")

          raise RuntimeError, message: "#{@provider_name} streaming error: #{message}"
        end

        def decode_stream_event(event, model),
          do: ReqLLM.Providers.OpenAI.decode_stream_event(event, model)

        def translate_options(_operation, _model, opts), do: {opts, []}

        def resolve_model(%LLMDB.Model{} = model), do: model

        def resolve_model(model_spec) when is_binary(model_spec) do
          model_id = String.replace_prefix(model_spec, @provider_name <> ":", "")
          build_model(model_id)
        end

        def build_model(model_id) do
          LLMDB.Model.new!(%{
            id: model_id,
            provider: String.to_atom(@provider_name),
            provider_model_id: model_id,
            name: model_id,
            limits: %{context: 128_000, output: 4096},
            capabilities: %{
              chat: true,
              tools: %{enabled: true, streaming: true, strict: false, parallel: false},
              streaming: %{text: true, tool_calls: true}
            },
            modalities: %{input: [:text], output: [:text]},
            deprecated: false,
            retired: false
          })
        end

        defp maybe_add_auth(request) do
          case @provider_auth_key do
            key when is_binary(key) and key != "" ->
              Req.Request.put_header(request, "Authorization", "Bearer " <> key)

            _ ->
              request
          end
        end
      end

    Module.create(mod_name, contents, Macro.Env.location(__ENV__))
    Registry.register(@registry, provider_name, mod_name)
    mod_name
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case Loomkin.Config.get(:provider, :endpoints) do
      %{} = endpoints ->
        Enum.each(endpoints, fn
          {_name, %{url: nil}} ->
            :ok

          {_name, %{url: ""}} ->
            :ok

          {provider_name, %{url: url, auth_key: auth_key}} when is_binary(url) and url != "" ->
            register_endpoint(to_string(provider_name), url, auth_key)
            :ok
        end)

      _ ->
        :ok
    end

    {:ok, %{}}
  end
end
