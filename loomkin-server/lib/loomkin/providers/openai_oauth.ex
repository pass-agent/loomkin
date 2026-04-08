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

  require Logger

  use ReqLLM.Provider,
    id: :openai_oauth,
    default_base_url: "https://chatgpt.com/backend-api"

  alias Loomkin.Auth.TokenStore
  alias Loomkin.Auth.Providers.OpenAI, as: OpenAIAuth
  alias Loomkin.Providers.OpenAICodexModels

  @openai ReqLLM.Providers.OpenAI
  @responses_api ReqLLM.Providers.OpenAI.ResponsesAPI

  @provider_schema [
    openai_parallel_tool_calls: [
      type: :boolean,
      doc: "Override parallel tool call behavior for OpenAI responses requests"
    ],
    openai_structured_output_mode: [
      type: {:in, [:auto, :json_schema, :tool_strict]},
      doc: "Structured output mode for OpenAI responses requests"
    ],
    openai_json_schema_strict: [
      type: :boolean,
      doc: "Whether structured JSON schema output should be strict"
    ],
    max_completion_tokens: [
      type: :integer,
      doc: "Maximum completion tokens (required for reasoning models)"
    ],
    response_format: [
      type: :map,
      doc: "Response format configuration for structured output"
    ],
    previous_response_id: [
      type: :string,
      doc: "Previous response id for responses-api resume flows"
    ],
    tool_outputs: [
      type: {:list, :any},
      doc: "Tool outputs for responses-api resume flows"
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
            :response_format,
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
        :response_format,
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

    req_opts =
      user_opts
      |> ReqLLM.Provider.Defaults.filter_req_opts()
      |> Keyword.delete(:base_url)

    request
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer #{oauth_token}")
    |> Req.Request.put_header("chatgpt-account-id", account_id || "")
    |> Req.Request.put_header("openai-beta", "responses=experimental")
    |> Req.Request.put_header("originator", "opencode")
    |> Req.Request.put_header("accept", "text/event-stream")
    |> Req.Request.merge_options(
      [model: get_api_model_id(model), base_url: base_url()] ++ req_opts
    )
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
        patched = patch_codex_body(body_map, request.options[:model])
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
        {"originator", "opencode"}
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
    @responses_api.decode_stream_event(event, model)
  end

  @doc false
  def inject_instructions_from_input(body_map) when not is_map(body_map), do: body_map

  def inject_instructions_from_input(body_map) do
    input = Map.get(body_map, "input", [])

    {system_items, non_system_items} =
      Enum.split_with(input, fn item ->
        is_map(item) and item["role"] == "system"
      end)

    instructions =
      system_items
      |> Enum.flat_map(fn item -> extract_system_text(item["content"]) end)
      |> Enum.join("\n")
      |> String.trim()

    body_map
    |> Map.delete("max_output_tokens")
    |> Map.put("input", non_system_items)
    |> maybe_put_instructions(instructions)
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
        status = TokenStore.get_status(:openai) || %{}
        stored_account_id = Map.get(status, :account_id) || Map.get(status, "account_id")
        derived_account_id = OpenAIAuth.extract_account_id(token)

        maybe_log_token_diagnostics(token, derived_account_id, stored_account_id, status)

        account_id = derived_account_id || stored_account_id

        {:ok, {token, account_id}}
    end
  end

  defp resolve_model(model_spec) when is_binary(model_spec) do
    canonical =
      model_spec
      |> String.replace_prefix("openai_oauth:", "openai:")

    case ReqLLM.model(canonical) do
      {:error, :not_found} -> OpenAICodexModels.resolve_model(canonical)
      result -> result
    end
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
      Logger.warning(
        "[Kin:openai_oauth] upstream 404 model=#{inspect(request.options[:model])} body=#{preview_body(body_str)}"
      )

      @openai.decode_response({request, response})
    end
  end

  defp preview_body(body) when is_binary(body) and byte_size(body) > 220 do
    binary_part(body, 0, 220) <> "..."
  end

  defp preview_body(body), do: body

  defp maybe_log_token_diagnostics(token, derived_account_id, stored_account_id, status)
       when is_binary(token) do
    scopes = Map.get(status, :scopes) || Map.get(status, "scopes")
    segment_count = token |> String.split(".") |> length()

    if is_nil(derived_account_id) and not is_nil(stored_account_id) do
      Logger.debug(
        "[Kin:openai_oauth] using stored account id because token claims were unavailable token_segments=#{segment_count} stored_account_id=#{inspect(stored_account_id)}"
      )
    end

    if suspicious_test_token?(token, stored_account_id, scopes) do
      Logger.warning(
        "[Kin:openai_oauth] suspicious oauth token detected len=#{byte_size(token)} token_segments=#{segment_count} stored_account_id=#{inspect(stored_account_id)} scopes=#{inspect(scopes)} reconnect_openai=true"
      )
    end
  end

  defp suspicious_test_token?(token, stored_account_id, scopes) do
    String.starts_with?(token, "test-") or scopes == "test" or
      (is_binary(stored_account_id) and String.contains?(stored_account_id, "test"))
  end

  defp log_tool_resume_shape(model_label, body_map, original_previous_response_id)
       when is_map(body_map) do
    input = Map.get(body_map, "input", [])

    function_call_count =
      Enum.count(input, &(is_map(&1) and Map.get(&1, "type") == "function_call"))

    function_output_count =
      Enum.count(input, &(is_map(&1) and Map.get(&1, "type") == "function_call_output"))

    if original_previous_response_id || function_call_count > 0 || function_output_count > 0 do
      Logger.debug(
        "[Kin:openai_oauth] resume_shape model=#{inspect(model_label)} dropped_previous_response_id=#{inspect(original_previous_response_id)} function_calls=#{function_call_count} function_outputs=#{function_output_count}"
      )
    end

    if function_call_count > 0 and function_output_count == 0 do
      Logger.warning(
        "[Kin:openai_oauth] function calls present without tool outputs model=#{inspect(model_label)}"
      )
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
        |> patch_codex_body(get_api_model_id(model))
        |> Jason.encode!()

      _ ->
        body_str
    end
  end

  defp patch_codex_body(body_map, model_label) when is_map(body_map) do
    previous_response_id = Map.get(body_map, "previous_response_id")

    patched =
      body_map
      |> inject_instructions_from_input()
      |> Map.delete("previous_response_id")
      |> drop_stale_function_calls(model_label)
      |> Map.put("store", false)
      |> Map.put("stream", true)

    log_tool_resume_shape(model_label, patched, previous_response_id)
    log_empty_input_shape(model_label, patched)
    patched
  end

  defp drop_stale_function_calls(body_map, model_label) when is_map(body_map) do
    input = Map.get(body_map, "input", [])

    output_call_ids =
      input
      |> Enum.flat_map(fn
        %{"type" => "function_call_output", "call_id" => call_id} when is_binary(call_id) ->
          [call_id]

        _ ->
          []
      end)
      |> MapSet.new()

    {filtered_input, dropped_count} =
      Enum.reduce(input, {[], 0}, fn
        %{"type" => "function_call", "call_id" => call_id} = item, {acc, dropped}
        when is_binary(call_id) ->
          if MapSet.member?(output_call_ids, call_id) do
            {[item | acc], dropped}
          else
            {acc, dropped + 1}
          end

        item, {acc, dropped} ->
          {[item | acc], dropped}
      end)

    if dropped_count > 0 do
      Logger.debug(
        "[Kin:openai_oauth] dropped stale function calls model=#{inspect(model_label)} count=#{dropped_count}"
      )
    end

    Map.put(body_map, "input", Enum.reverse(filtered_input))
  end

  defp log_empty_input_shape(model_label, body_map) when is_map(body_map) do
    input = Map.get(body_map, "input", [])

    cond do
      input == [] ->
        Logger.warning(
          "[Kin:openai_oauth] codex request has empty input model=#{inspect(model_label)} instructions_present=#{Map.has_key?(body_map, "instructions")}"
        )

      Enum.all?(input, fn item ->
        is_map(item) and Map.get(item, "type") == "function_call_output"
      end) ->
        Logger.warning(
          "[Kin:openai_oauth] codex request has tool-output-only input model=#{inspect(model_label)} count=#{length(input)}"
        )

      true ->
        :ok
    end
  end

  defp maybe_put_instructions(body_map, ""), do: body_map

  defp maybe_put_instructions(body_map, instructions),
    do: Map.put(body_map, "instructions", instructions)

  defp extract_system_text(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => type, "text" => text}
      when type in ["input_text", "text"] and is_binary(text) and text != "" ->
        [text]

      _ ->
        []
    end)
  end

  defp extract_system_text(_), do: []
end
