defmodule Loomkin.Providers.OpenAIOAuth do
  @moduledoc """
  Custom ReqLLM provider for OpenAI API access via ChatGPT Codex OAuth tokens.

  This provider wraps the stock OpenAI provider but targets the **ChatGPT consumer
  backend** (`chatgpt.com/backend-api`) instead of the Platform API (`api.openai.com/v1`).
  It registers as `:openai_oauth` and supports models accessible via ChatGPT Plus/Pro
  subscriptions (GPT-5, GPT-5.1 Codex, etc.).

  ## Key differences from stock `:openai`

  - Base URL: `https://chatgpt.com/backend-api` (not `api.openai.com/v1`)
  - URL rewriting: `/responses` → `/codex/responses`
  - Auth: `Authorization: Bearer <oauth_token>` (not `x-api-key`)
  - Extra headers: `chatgpt-account-id`, `OpenAI-Beta: responses=experimental`, `originator: codex_cli_rs`
  - Body: `store: false` is mandatory, `stream: true` always set
  - Account ID is extracted from the JWT access token at
    `payload["https://api.openai.com/auth"]["chatgpt_account_id"]`

  ## Usage

  Once registered, models are addressed as `"openai_oauth:gpt-5.1-codex"`.
  The provider automatically fetches the current OAuth token from
  `Loomkin.Auth.TokenStore` for each request.

  ## Registration

  Call `Loomkin.Providers.OpenAIOAuth.register!/0` during application
  startup (after TokenStore is started).
  """

  use ReqLLM.Provider,
    id: :openai_oauth,
    default_base_url: "https://chatgpt.com/backend-api"

  alias Loomkin.Auth.TokenStore
  alias Loomkin.Auth.Providers.OpenAI, as: OpenAIAuth

  @openai ReqLLM.Providers.OpenAI
  @responses_api ReqLLM.Providers.OpenAI.ResponsesAPI

  @provider_schema [
    max_completion_tokens: [
      type: :integer,
      doc: "Maximum completion tokens (required for reasoning models)"
    ],
    service_tier: [
      type: {:or, [:atom, :string]},
      doc: "Service tier for request prioritization"
    ],
    verbosity: [
      type: {:or, [:atom, :string]},
      doc: "Constrains the verbosity of the model's response ('low', 'medium', 'high')"
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
    with {:ok, {oauth_token, account_id}} <- fetch_token_and_account(),
         {:ok, model} <- resolve_model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         opts_with_key = Keyword.put(opts_with_context, :api_key, oauth_token),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(@openai, :chat, model, opts_with_key) do
      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      timeout =
        Keyword.get(
          processed_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :thinking_timeout, 300_000)
        )

      req_keys =
        supported_provider_options() ++
          [
            :context,
            :operation,
            :text,
            :stream,
            :model,
            :provider_options,
            :api_key,
            :tools,
            :tool_choice,
            :max_completion_tokens,
            :reasoning_effort,
            :service_tier,
            :compiled_schema,
            :temperature,
            :max_tokens,
            :n,
            :fixture,
            :on_unsupported,
            :receive_timeout,
            :req_http_options,
            :base_url,
            :app_referer,
            :app_title
          ]

      request =
        Req.new(
          [
            url: "/codex/responses",
            method: :post,
            receive_timeout: timeout,
            pool_timeout: timeout,
            connect_options: [timeout: timeout]
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: get_api_model_id(model),
              base_url: base_url()
            ]
        )
        |> attach_with_account(model, processed_opts, oauth_token, account_id)

      {:ok, request}
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    prepare_request(:chat, model_spec, prompt, opts)
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
    case fetch_token_and_account() do
      {:ok, {oauth_token, account_id}} ->
        attach_with_account(request, model, user_opts, oauth_token, account_id)

      {:error, _} ->
        raise "No OAuth token available for OpenAI. Connect via Settings."
    end
  end

  defp attach_with_account(request, model, user_opts, oauth_token, account_id) do
    extra_option_keys =
      [
        :model,
        :compiled_schema,
        :temperature,
        :max_tokens,
        :max_completion_tokens,
        :api_key,
        :tools,
        :tool_choice,
        :stream,
        :thinking,
        :provider_options,
        :reasoning_effort,
        :service_tier,
        :fixture,
        :on_unsupported,
        :n,
        :receive_timeout,
        :req_http_options,
        :base_url,
        :context,
        :app_referer,
        :app_title,
        :text,
        :operation
      ] ++
        supported_provider_options()

    req_opts = ReqLLM.Provider.Defaults.filter_req_opts(user_opts)

    request
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer #{oauth_token}")
    |> Req.Request.put_header("chatgpt-account-id", account_id || "")
    |> Req.Request.put_header("openai-beta", "responses=experimental")
    |> Req.Request.put_header("originator", "codex_cli_rs")
    |> Req.Request.put_header("accept", "text/event-stream")
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
    encoded = @responses_api.encode_body(request)

    case Jason.decode(encoded.body) do
      {:ok, body_map} ->
        patched =
          body_map
          |> Map.put("store", false)
          |> Map.put("stream", true)

        Map.put(encoded, :body, Jason.encode!(patched))

      _ ->
        encoded
    end
  end

  @impl ReqLLM.Provider
  def decode_response({request, response}) do
    case response.status do
      404 ->
        handle_404_as_rate_limit({request, response})

      _ ->
        @openai.decode_response({request, response})
    end
  end

  @impl ReqLLM.Provider
  def extract_usage(body, model) do
    @openai.extract_usage(body, model)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    {oauth_token, account_id} =
      case fetch_token_and_account() do
        {:ok, result} -> result
        {:error, _} -> raise "No OAuth token available for OpenAI. Connect via Settings."
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

    {_req_opts, user_opts} = Keyword.split(opts, req_only_keys)

    opts_to_process = Keyword.merge(user_opts, context: context, stream: true)

    with {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(@openai, :chat, model, opts_to_process) do
      {translated_opts, _warnings} = translate_options(:chat, model, processed_opts)

      timeout =
        Keyword.get(
          translated_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :thinking_timeout, 300_000)
        )

      translated_opts = Keyword.put_new(translated_opts, :receive_timeout, timeout)

      headers = [
        {"Accept", "text/event-stream"},
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{oauth_token}"},
        {"chatgpt-account-id", account_id || ""},
        {"OpenAI-Beta", "responses=experimental"},
        {"originator", "codex_cli_rs"}
      ]

      body = build_stream_body(model, context, translated_opts)
      url = "#{base_url()}/codex/responses"

      finch_request = Finch.build(:post, url, headers, body)
      {:ok, finch_request}
    end
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build OpenAIOAuth stream request: #{inspect(error)}"
       )}
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    @openai.decode_stream_event(event, model)
  end

  @impl ReqLLM.Provider
  def translate_options(operation, model, opts) do
    @openai.translate_options(operation, model, opts)
  end

  # ── Internal helpers ────────────────────────────────────────────────

  defp fetch_token_and_account do
    case TokenStore.get_access_token(:openai) do
      nil ->
        {:error, :no_oauth_token}

      token ->
        account_id = OpenAIAuth.extract_account_id(token)

        {:ok, {token, account_id}}
    end
  end

  defp resolve_model(model_spec) when is_binary(model_spec) do
    canonical =
      model_spec
      |> String.replace_prefix("openai_oauth:", "openai:")

    ReqLLM.model(canonical)
  end

  defp resolve_model(model_spec), do: ReqLLM.model(model_spec)

  defp get_api_model_id(model) do
    model.provider_model_id || model.id
  end

  defp handle_404_as_rate_limit({request, %Req.Response{body: body} = response}) do
    body_str = if is_binary(body), do: body, else: Jason.encode!(body)
    haystack = String.downcase(body_str)

    if String.contains?(haystack, "usage_limit_reached") or
         String.contains?(haystack, "usage_not_included") or
         String.contains?(haystack, "rate_limit_exceeded") or
         String.contains?(haystack, "usage limit") do
      {request, %{response | status: 429}}
    else
      @openai.decode_response({request, response})
    end
  end

  defp build_stream_body(model, context, opts) do
    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(
        :options,
        Map.new(
          [
            model: get_api_model_id(model),
            context: context,
            stream: true
          ] ++ Keyword.delete(opts, :finch_name)
        )
      )

    encoded_request = @responses_api.encode_body(temp_request)
    body_str = encoded_request.body

    case Jason.decode(body_str) do
      {:ok, body_map} ->
        body_map
        |> Map.put("store", false)
        |> Map.put("stream", true)
        |> Jason.encode!()

      _ ->
        body_str
    end
  end
end
