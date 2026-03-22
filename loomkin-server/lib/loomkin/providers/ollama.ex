defmodule Loomkin.Providers.Ollama do
  @moduledoc """
  ReqLLM provider for Ollama local LLM inference.

  Ollama exposes an OpenAI-compatible API at `http://localhost:11434/v1/`,
  so this provider delegates body encoding/decoding to the stock OpenAI
  ChatAPI driver. The key differences from stock OpenAI:

  - Base URL: `http://localhost:11434/v1` (configurable via `OLLAMA_HOST`)
  - Auth: No API key required (sends `"ollama"` as a dummy bearer token)
  - Model resolution: Builds synthetic `LLMDB.Model` structs since Ollama
    models aren't in LLMDB

  ## Usage

      # After registration, use "ollama:model_name" as the model spec:
      Loomkin.LLM.stream_text("ollama:qwen3:8b", messages, opts)

  ## Configuration

      # Default: http://localhost:11434
      export OLLAMA_HOST=http://192.168.1.10:11434
  """

  use ReqLLM.Provider,
    id: :ollama,
    default_base_url: "http://localhost:11434/v1"

  @chat_api ReqLLM.Providers.OpenAI.ChatAPI

  # ── Registration ────────────────────────────────────────────────────

  def register! do
    ReqLLM.Providers.register!(__MODULE__)
  end

  # ── Model Resolution ────────────────────────────────────────────────

  @doc """
  Builds a synthetic LLMDB.Model struct for an Ollama model.

  Since Ollama models aren't cataloged in LLMDB, we construct a minimal
  model struct with sensible defaults.
  """
  def build_model(model_id) do
    LLMDB.Model.new!(%{
      id: model_id,
      provider: :ollama,
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

  # ── Provider callbacks ──────────────────────────────────────────────

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    model = resolve_model(model_spec)

    with {:ok, context} <- ReqLLM.Context.normalize(prompt, opts) do
      opts_with_context = Keyword.put(opts, :context, context)
      http_opts = Keyword.get(opts, :req_http_options, [])
      timeout = Keyword.get(opts, :receive_timeout, 120_000)

      req_keys =
        supported_provider_options() ++
          [
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

      request =
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
              base_url: ollama_base_url(),
              api_mod: @chat_api
            ]
        )
        |> attach(model, opts_with_context)

      {:ok, request}
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "operation: #{inspect(operation)} not supported by Ollama provider"
     )}
  end

  @impl ReqLLM.Provider
  def attach(request, model, user_opts) do
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
    |> Req.Request.put_header("authorization", "Bearer ollama")
    |> Req.Request.merge_options(user_opts)
    |> Req.Request.put_private(:req_llm_model, model)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    @chat_api.encode_body(request)
  end

  @impl ReqLLM.Provider
  def decode_response({request, response}) do
    @chat_api.decode_response({request, response})
  end

  @impl ReqLLM.Provider
  def extract_usage(body, model) do
    ReqLLM.Providers.OpenAI.extract_usage(body, model)
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    headers = [
      {"Accept", "text/event-stream"},
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer ollama"}
    ]

    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.put(:stream, true)
      |> Keyword.put(:base_url, ollama_base_url())

    body = build_stream_body(model, context, cleaned_opts)
    url = "#{ollama_base_url()}/chat/completions"

    {:ok, Finch.build(:post, url, headers, Jason.encode!(body))}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Ollama stream request: #{inspect(error)}"
       )}
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    ReqLLM.Providers.OpenAI.decode_stream_event(event, model)
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    {opts, []}
  end

  # ── Public helpers ──────────────────────────────────────────────────

  @doc """
  Returns the configured Ollama base URL (OpenAI-compat endpoint).
  """
  def ollama_base_url do
    host = System.get_env("OLLAMA_HOST") || "http://localhost:11434"

    host
    |> String.trim_trailing("/")
    |> Kernel.<>("/v1")
  end

  @doc """
  Returns the Ollama native API base URL (for model discovery).
  """
  def ollama_api_url do
    host = System.get_env("OLLAMA_HOST") || "http://localhost:11434"
    String.trim_trailing(host, "/")
  end

  @doc """
  Fetches the list of locally available Ollama models.

  Calls Ollama's native `/api/tags` endpoint.
  Returns `{:ok, [model_info]}` or `{:error, reason}`.
  """
  def list_models do
    url = "#{ollama_api_url()}/api/tags"

    case Req.get(url, receive_timeout: 5_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} ->
        {:ok, models}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Ollama returned HTTP #{status}"}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :not_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true if Ollama is reachable.
  """
  def available? do
    case list_models() do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ── Internal helpers ────────────────────────────────────────────────

  defp resolve_model(%LLMDB.Model{} = model), do: model

  defp resolve_model(model_spec) when is_binary(model_spec) do
    model_id = String.replace_prefix(model_spec, "ollama:", "")
    build_model(model_id)
  end

  defp build_stream_body(model, context, opts) do
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
            api_mod: @chat_api
          ] ++ Keyword.delete(opts, :finch_name)
        )
      )

    encoded = @chat_api.encode_body(temp_request)

    case Jason.decode(encoded.body) do
      {:ok, body_map} ->
        body_map
        |> Map.put("stream", true)

      _ ->
        %{"model" => model.id, "stream" => true}
    end
  end
end
