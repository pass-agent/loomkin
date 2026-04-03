defmodule Loomkin.Providers.GoogleOAuth do
  @moduledoc """
  Custom ReqLLM provider for Google Generative Language API access via OAuth
  Bearer tokens.

  This provider wraps the stock Google provider but replaces the API key
  query parameter (`?key=...`) with `Authorization: Bearer <token>` from
  the TokenStore. It registers as `:google_oauth` and supports the same
  models as the stock Google provider.

  ## Usage

  Once registered, models are addressed as `"google_oauth:gemini-2.0-flash"`.
  The provider automatically fetches the current OAuth token from
  `Loomkin.Auth.TokenStore` for each request.

  ## Registration

  Call `Loomkin.Providers.GoogleOAuth.register!/0` during application
  startup (after TokenStore is started).
  """

  use ReqLLM.Provider,
    id: :google_oauth,
    default_base_url: "https://generativelanguage.googleapis.com/v1beta"

  alias Loomkin.Auth.TokenStore

  @google ReqLLM.Providers.Google

  @provider_schema [
    google_api_version: [
      type: {:in, ["v1", "v1beta"]},
      doc: "Google API version. Default is 'v1beta'."
    ],
    google_safety_settings: [
      type: {:list, :map},
      doc: "Safety filter configurations"
    ],
    google_candidate_count: [
      type: :pos_integer,
      doc: "Number of response candidates (default: 1)"
    ],
    google_thinking_budget: [
      type: :non_neg_integer,
      doc: "Thinking token budget for Gemini 2.5 models"
    ],
    google_grounding: [
      type: :map,
      doc: "Enable Google Search grounding"
    ],
    google_url_context: [
      type: {:or, [:boolean, :map]},
      doc: "Enable URL context grounding"
    ],
    dimensions: [
      type: :pos_integer,
      doc: "Embedding vector dimensions"
    ],
    task_type: [
      type: :string,
      doc: "Embedding task type"
    ],
    cached_content: [
      type: :string,
      doc: "Reference to cached content"
    ],
    google_auth_header: [
      type: :boolean,
      doc: "Ignored — OAuth always uses Bearer header"
    ]
  ]

  # ── Registration ────────────────────────────────────────────────────

  @doc """
  Register this provider with ReqLLM's provider registry.
  Call during application startup.
  """
  def register! do
    ReqLLM.Providers.register!(__MODULE__)
  end

  # ── Provider callbacks ──────────────────────────────────────────────

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, oauth_token} <- fetch_token(),
         {:ok, model} <- resolve_model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         opts_with_key = Keyword.put(opts_with_context, :api_key, oauth_token),
         {:ok, processed_opts0} <-
           ReqLLM.Provider.Options.process(@google, :chat, model, opts_with_key),
         :ok <- validate_version_feature_compat(processed_opts0) do
      processed_opts =
        Keyword.put(processed_opts0, :base_url, effective_base_url(processed_opts0))

      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      endpoint =
        if processed_opts[:stream], do: ":streamGenerateContent", else: ":generateContent"

      req_keys =
        supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options, :tools, :tool_choice]

      base_params = if processed_opts[:stream], do: [alt: "sse"], else: []

      timeout =
        Keyword.get(
          processed_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :receive_timeout, 30_000)
        )

      request =
        Req.new(
          [
            url: "/models/#{get_api_model_id(model)}#{endpoint}",
            method: :post,
            params: base_params,
            receive_timeout: timeout
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: get_api_model_id(model),
              base_url: processed_opts[:base_url]
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    prepare_request(:chat, model_spec, prompt, Keyword.put(opts, :operation, :object))
  end

  @impl ReqLLM.Provider
  def prepare_request(:embedding, model_spec, prompt, opts) do
    with {:ok, oauth_token} <- fetch_token(),
         {:ok, model} <- resolve_model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         opts_with_key = Keyword.put(opts_with_context, :api_key, oauth_token),
         {:ok, processed_opts0} <-
           ReqLLM.Provider.Options.process(@google, :embedding, model, opts_with_key) do
      processed_opts =
        Keyword.put(processed_opts0, :base_url, effective_base_url(processed_opts0))

      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      req_keys =
        supported_provider_options() ++
          [:context, :operation, :text, :stream, :model, :provider_options]

      timeout =
        Keyword.get(
          processed_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :receive_timeout, 30_000)
        )

      request =
        Req.new(
          [
            url: "/models/#{get_api_model_id(model)}:embedContent",
            method: :post,
            receive_timeout: timeout
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: get_api_model_id(model),
              base_url: processed_opts[:base_url]
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}"
     )}
  end

  @impl ReqLLM.Provider
  def attach(request, model, user_opts) do
    oauth_token =
      case Keyword.get(user_opts, :api_key) do
        nil ->
          case fetch_token() do
            {:ok, token} -> token
            {:error, _} -> raise "No OAuth token available for Google. Connect via Settings."
          end

        token ->
          token
      end

    extra_option_keys =
      [
        :model,
        :compiled_schema,
        :temperature,
        :max_tokens,
        :app_referer,
        :app_title,
        :fixture,
        :tools,
        :tool_choice,
        :n,
        :top_p,
        :top_k,
        :frequency_penalty,
        :presence_penalty,
        :seed,
        :stop,
        :user,
        :system_prompt,
        :reasoning_effort,
        :reasoning_token_budget,
        :stream,
        :provider_options,
        :api_key,
        :context,
        :operation
      ] ++
        supported_provider_options()

    req_opts = ReqLLM.Provider.Defaults.filter_req_opts(user_opts)

    request
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.put_header("authorization", "Bearer #{oauth_token}")
    |> Req.Request.put_header("content-type", "application/json")
    |> maybe_put_user_project_header()
    |> Req.Request.merge_options([model: get_api_model_id(model)] ++ req_opts)
    |> Req.Request.put_private(:req_llm_model, model)
    |> ReqLLM.Step.Error.attach()
    |> ReqLLM.Step.Retry.attach(user_opts)
    |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    request = @google.encode_body(request)

    case request.body do
      body when is_binary(body) ->
        stripped = body |> Jason.decode!() |> strip_additional_properties() |> Jason.encode!()
        %{request | body: stripped}

      {:json, body} ->
        %{request | body: {:json, strip_additional_properties(body)}}

      _ ->
        request
    end
  end

  @impl ReqLLM.Provider
  def decode_response({request, response}) do
    @google.decode_response({request, response})
  end

  @impl ReqLLM.Provider
  def extract_usage(body, model) do
    @google.extract_usage(body, model)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    oauth_token =
      case Keyword.get(opts, :api_key) do
        nil ->
          case fetch_token() do
            {:ok, token} -> token
            {:error, _} -> raise "No OAuth token available for Google. Connect via Settings."
          end

        token ->
          token
      end

    req_only_keys = [
      :params,
      :model,
      :base_url,
      :finch_name,
      :fixture,
      :retry,
      :max_retries,
      :retry_log_level
    ]

    {req_opts, user_opts} = Keyword.split(opts, req_only_keys)

    operation = Keyword.get(user_opts, :operation, :chat)

    opts_to_process =
      Keyword.merge(user_opts, context: context, stream: true, api_key: oauth_token)

    with {:ok, processed_opts0} <-
           ReqLLM.Provider.Options.process(@google, operation, model, opts_to_process),
         :ok <- validate_version_feature_compat(processed_opts0) do
      computed_base_url = effective_base_url(processed_opts0)
      processed_opts = Keyword.put(processed_opts0, :base_url, computed_base_url)
      base_url = Keyword.get(req_opts, :base_url, processed_opts[:base_url])
      opts_with_base = Keyword.merge(processed_opts, base_url: base_url, model_struct: model)

      headers =
        [
          {"Accept", "text/event-stream"},
          {"Content-Type", "application/json"},
          {"Authorization", "Bearer #{oauth_token}"}
        ]
        |> then(fn h ->
          case gcp_project_id() do
            nil -> h
            id -> h ++ [{"x-goog-user-project", id}]
          end
        end)

      url = "#{base_url}/models/#{get_api_model_id(model)}:streamGenerateContent?alt=sse"

      body = build_stream_body(model, context, opts_with_base)

      finch_request = Finch.build(:post, url, headers, body)
      {:ok, finch_request}
    end
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build GoogleOAuth stream request: #{inspect(error)}"
       )}
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    @google.decode_stream_event(event, model)
  end

  @impl ReqLLM.Provider
  def translate_options(operation, model, opts) do
    @google.translate_options(operation, model, opts)
  end

  # ── Internal helpers ────────────────────────────────────────────────

  defp fetch_token do
    case TokenStore.get_access_token(:google) do
      nil -> {:error, :no_oauth_token}
      token -> {:ok, token}
    end
  end

  defp resolve_model(model_spec) when is_binary(model_spec) do
    canonical =
      model_spec
      |> String.replace_prefix("google_oauth:", "google:")

    ReqLLM.model(canonical)
  end

  defp resolve_model(model_spec), do: ReqLLM.model(model_spec)

  defp get_api_model_id(model) do
    model.provider_model_id || model.id
  end

  defp effective_base_url(processed_opts) do
    base_url = Keyword.get(processed_opts, :base_url)
    default = "https://generativelanguage.googleapis.com/v1beta"

    if base_url == default or base_url == "https://generativelanguage.googleapis.com" do
      case resolve_api_version(processed_opts) do
        "v1" -> "https://generativelanguage.googleapis.com/v1"
        _ -> default
      end
    else
      base_url || default
    end
  end

  defp resolve_api_version(opts) when is_list(opts) do
    provider = Keyword.get(opts, :provider_options, [])

    case Keyword.get(provider, :google_api_version) do
      "v1" -> "v1"
      "v1beta" -> "v1beta"
      _ -> nil
    end
  end

  defp validate_version_feature_compat(processed_opts) do
    case {resolve_api_version(processed_opts), has_grounding?(processed_opts),
          has_tools?(processed_opts)} do
      {"v1", true, _} ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter:
             ~s/google_grounding requires google_api_version: "v1beta" (or remove the v1 override to use the default)/
         )}

      {"v1", _, true} ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter:
             ~s/function calling (tools) requires google_api_version: "v1beta" (or remove the v1 override to use the default)/
         )}

      _ ->
        :ok
    end
  end

  defp has_grounding?(opts) do
    provider = Keyword.get(opts, :provider_options, [])

    case Keyword.get(provider, :google_grounding) do
      m when is_map(m) and map_size(m) > 0 -> true
      _ -> false
    end
  end

  defp has_tools?(opts) do
    case Keyword.get(opts, :tools) do
      tools when is_list(tools) and tools != [] -> true
      _ -> false
    end
  end

  defp strip_additional_properties(map) when is_map(map) do
    map
    |> Map.delete("additionalProperties")
    |> Map.new(fn {k, v} -> {k, strip_additional_properties(v)} end)
  end

  defp strip_additional_properties(list) when is_list(list) do
    Enum.map(list, &strip_additional_properties/1)
  end

  defp strip_additional_properties(value), do: value

  defp gcp_project_id do
    case Loomkin.Config.get(:auth, :google) do
      %{gcp_project_id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp maybe_put_user_project_header(request) do
    case gcp_project_id() do
      nil -> request
      id -> Req.Request.put_header(request, "x-goog-user-project", id)
    end
  end

  defp build_stream_body(model, context, opts) do
    operation = Keyword.get(opts, :operation, :chat)
    compiled_schema = Keyword.get(opts, :compiled_schema)

    base_options =
      [
        model: model.id,
        context: context,
        stream: true,
        operation: operation
      ]
      |> then(fn o ->
        if compiled_schema, do: Keyword.put(o, :compiled_schema, compiled_schema), else: o
      end)

    all_options = Keyword.merge(base_options, Keyword.delete(opts, :finch_name))

    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(:options, Map.new(all_options))

    encoded_request = @google.encode_body(temp_request)

    case encoded_request.body do
      body when is_binary(body) ->
        body |> Jason.decode!() |> strip_additional_properties() |> Jason.encode!()

      {:json, body} ->
        {:json, strip_additional_properties(body)}

      other ->
        other
    end
  end
end
