defmodule Loomkin.Providers.AnthropicOAuth do
  @moduledoc """
  Custom ReqLLM provider for Anthropic API access via OAuth Bearer tokens.

  This provider wraps the stock Anthropic provider but replaces the
  `x-api-key` authentication with `Authorization: Bearer <token>` from
  the TokenStore. It registers as `:anthropic_oauth` and supports the
  same models as the stock Anthropic provider.

  ## Usage

  Once registered, models are addressed as `"anthropic_oauth:claude-sonnet-4-6"`.
  The provider automatically fetches the current OAuth token from
  `Loomkin.Auth.TokenStore` for each request.

  ## Registration

  Call `Loomkin.Providers.AnthropicOAuth.register!/0` during application
  startup (after TokenStore is started).
  """

  use ReqLLM.Provider,
    id: :anthropic_oauth,
    default_base_url: "https://api.anthropic.com"

  alias Loomkin.Auth.TokenStore

  @anthropic ReqLLM.Providers.Anthropic

  # Delegate schema to Anthropic provider
  @provider_schema [
    anthropic_top_k: [
      type: :pos_integer,
      doc: "Sample from the top K options for each subsequent token (1-40)"
    ],
    anthropic_version: [
      type: :string,
      doc: "Anthropic API version header"
    ],
    anthropic_beta: [
      type: {:list, :string},
      doc: "Beta feature flags"
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
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(@anthropic, :chat, model, opts_with_key) do
      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      default_timeout =
        if Keyword.has_key?(processed_opts, :thinking) do
          Application.get_env(:req_llm, :thinking_timeout, 300_000)
        else
          Application.get_env(:req_llm, :receive_timeout, 120_000)
        end

      timeout = Keyword.get(processed_opts, :receive_timeout, default_timeout)
      base_url = Keyword.get(processed_opts, :base_url, base_url())

      req_keys =
        supported_provider_options() ++
          [
            :context,
            :model,
            :compiled_schema,
            :temperature,
            :max_tokens,
            :api_key,
            :tools,
            :tool_choice,
            :stream,
            :thinking,
            :provider_options,
            :reasoning_effort,
            :fixture,
            :on_unsupported,
            :n,
            :receive_timeout,
            :req_http_options,
            :base_url,
            :app_referer,
            :app_title,
            :anthropic_version,
            :anthropic_beta
          ]

      request =
        Req.new(
          [
            base_url: base_url,
            url: "/v1/messages",
            method: :post,
            receive_timeout: timeout,
            pool_timeout: timeout,
            connect_options: [timeout: timeout]
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++ [model: get_api_model_id(model)]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    # For object generation, delegate to chat with appropriate options
    # (structured output works the same way, just the auth differs)
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
    oauth_token =
      case Keyword.get(user_opts, :api_key) do
        nil ->
          case fetch_token() do
            {:ok, token} -> token
            {:error, _} -> raise "No OAuth token available for Anthropic. Connect via Settings."
          end

        token ->
          token
      end

    extra_option_keys = [
      :model,
      :compiled_schema,
      :temperature,
      :max_tokens,
      :api_key,
      :tools,
      :tool_choice,
      :stream,
      :thinking,
      :provider_options,
      :reasoning_effort,
      :fixture,
      :on_unsupported,
      :n,
      :receive_timeout,
      :req_http_options,
      :base_url,
      :context,
      :anthropic_version,
      :anthropic_beta,
      :app_referer,
      :app_title
    ]

    anthropic_version =
      Keyword.get(user_opts, :anthropic_version, "2023-06-01")

    request
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer #{oauth_token}")
    |> Req.Request.put_header("anthropic-version", anthropic_version)
    |> maybe_add_beta_header(user_opts)
    |> Req.Request.merge_options(user_opts)
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
    # Delegate to Anthropic's encode_body since the wire format is identical
    @anthropic.encode_body(request)
  end

  @impl ReqLLM.Provider
  def decode_response({request, response}) do
    @anthropic.decode_response({request, response})
  end

  @impl ReqLLM.Provider
  def extract_usage(body, model) do
    @anthropic.extract_usage(body, model)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    oauth_token =
      case Keyword.get(opts, :api_key) do
        nil ->
          case fetch_token() do
            {:ok, token} -> token
            {:error, _} -> raise "No OAuth token available for Anthropic. Connect via Settings."
          end

        token ->
          token
      end

    {provider_options, standard_opts} = Keyword.pop(opts, :provider_options, [])
    flattened_opts = Keyword.merge(standard_opts, provider_options)

    {translated_opts, _warnings} = translate_options(:chat, model, flattened_opts)

    default_timeout =
      if Keyword.has_key?(translated_opts, :thinking) do
        Application.get_env(:req_llm, :thinking_timeout, 300_000)
      else
        Application.get_env(:req_llm, :receive_timeout, 120_000)
      end

    translated_opts = Keyword.put_new(translated_opts, :receive_timeout, default_timeout)

    base_url = ReqLLM.Provider.Options.effective_base_url(@anthropic, model, translated_opts)
    translated_opts = Keyword.put(translated_opts, :base_url, base_url)

    # Build headers with Bearer auth instead of x-api-key
    anthropic_version = Keyword.get(translated_opts, :anthropic_version, "2023-06-01")

    headers = [
      {"Accept", "text/event-stream"},
      {"content-type", "application/json"},
      {"authorization", "Bearer #{oauth_token}"},
      {"anthropic-version", anthropic_version}
    ]

    headers = headers ++ build_beta_headers(translated_opts)

    body =
      ReqLLM.Providers.Anthropic.Context.encode_request(context, %{model: get_api_model_id(model)})
      |> add_stream_options(translated_opts)

    url = "#{base_url}/v1/messages"
    finch_request = Finch.build(:post, url, headers, Jason.encode!(body))
    {:ok, finch_request}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build AnthropicOAuth stream request: #{inspect(error)}"
       )}
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    @anthropic.decode_stream_event(event, model)
  end

  @impl ReqLLM.Provider
  def translate_options(operation, model, opts) do
    @anthropic.translate_options(operation, model, opts)
  end

  # ── Internal helpers ────────────────────────────────────────────────

  defp fetch_token do
    case TokenStore.get_access_token(:anthropic) do
      nil -> {:error, :no_oauth_token}
      token -> {:ok, token}
    end
  end

  defp resolve_model(model_spec) when is_binary(model_spec) do
    # If the model string uses "anthropic_oauth:" prefix, resolve it as an anthropic model
    # since LLMDB knows about "anthropic:*" models but not "anthropic_oauth:*"
    canonical =
      model_spec
      |> String.replace_prefix("anthropic_oauth:", "anthropic:")

    ReqLLM.model(canonical)
  end

  defp resolve_model(model_spec), do: ReqLLM.model(model_spec)

  defp get_api_model_id(model) do
    model.provider_model_id || model.id
  end

  defp maybe_add_beta_header(request, opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])
    beta = Keyword.get(provider_opts, :anthropic_beta) || Keyword.get(opts, :anthropic_beta)

    if beta do
      Req.Request.put_header(request, "anthropic-beta", Enum.join(List.wrap(beta), ","))
    else
      request
    end
  end

  defp build_beta_headers(opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])
    beta = Keyword.get(provider_opts, :anthropic_beta) || Keyword.get(opts, :anthropic_beta)

    if beta do
      [{"anthropic-beta", Enum.join(List.wrap(beta), ",")}]
    else
      []
    end
  end

  defp add_stream_options(body, opts) do
    max_tokens =
      case Keyword.get(opts, :max_tokens) do
        nil -> 4096
        v -> v
      end

    body
    |> Map.put(:stream, true)
    |> Map.put(:max_tokens, max_tokens)
    |> maybe_add_thinking(opts)
    |> maybe_add_tools(opts)
  end

  defp maybe_add_thinking(body, opts) do
    case Keyword.get(opts, :thinking) do
      nil -> body
      thinking -> Map.put(body, :thinking, thinking)
    end
  end

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        body

      tools when is_list(tools) ->
        encoded_tools =
          Enum.map(tools, fn
            %ReqLLM.Tool{} = tool ->
              %{
                name: tool.name,
                description: tool.description,
                input_schema: tool.parameter_schema
              }

            other ->
              other
          end)

        Map.put(body, :tools, encoded_tools)

      _ ->
        body
    end
  end
end
