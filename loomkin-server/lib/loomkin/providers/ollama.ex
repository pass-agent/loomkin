defmodule Loomkin.Providers.Ollama do
  @moduledoc """
  ReqLLM provider for Ollama local LLM inference.

  Delegates OpenAI-compatible request handling to `Loomkin.Providers.OpenAICompatibleProvider`
  and adds Ollama-specific functionality:

  - Native `/api/tags` model discovery
  - Availability checks
  - Default `Bearer ollama` auth token

  ## Usage

      Loomkin.LLM.stream_text("ollama:qwen3:8b", messages, opts)

  ## Configuration

      [provider.endpoints]
      ollama = { url = "http://localhost:11434/v1" }
      # ollama = { url = "http://localhost:11434/v1", auth_key = "custom-token" }
  """

  use ReqLLM.Provider,
    id: :ollama,
    default_base_url: "http://localhost:11434/v1"

  alias Loomkin.Providers.OpenAICompatibleProvider

  # ── Registration ────────────────────────────────────────────────────

  def register!, do: ReqLLM.Providers.register!(__MODULE__)

  # ── Model Resolution ────────────────────────────────────────────────

  @doc """
  Builds a synthetic LLMDB.Model struct for an Ollama model.
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

  # ── Provider callbacks (delegated to OpenAICompat) ─────────────────

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    model = resolve_model(model_spec)

    with {:ok, context} <- ReqLLM.Context.normalize(prompt, opts) do
      opts_with_context = Keyword.put(opts, :context, context)

      request =
        OpenAICompatibleProvider.build_chat_request(model, ollama_base_url(), opts_with_context)
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
    request
    |> maybe_add_auth_header()
    |> OpenAICompatibleProvider.attach_openai_compat(model, user_opts)
  end

  @impl ReqLLM.Provider
  def encode_body(request), do: ReqLLM.Providers.OpenAI.ChatAPI.encode_body(request)

  @impl ReqLLM.Provider
  def decode_response(pair), do: ReqLLM.Providers.OpenAI.ChatAPI.decode_response(pair)

  @impl ReqLLM.Provider
  def extract_usage(body, model), do: ReqLLM.Providers.OpenAI.extract_usage(body, model)

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    headers = [
      {"Accept", "text/event-stream"},
      {"Content-Type", "application/json"},
      auth_header()
    ]

    {:ok,
     OpenAICompatibleProvider.build_stream_request(
       model,
       context,
       ollama_base_url(),
       headers,
       opts
     )}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Ollama stream request: #{inspect(error)}"
       )}
  end

  # WORKAROUND: req_llm's default_decode_stream_event silently drops SSE events
  # containing {"error": {...}} payloads (returns []). This intercepts error events
  # and raises so call_llm's try/rescue can surface the error to the UI.
  @impl ReqLLM.Provider
  def decode_stream_event(%{data: %{"error" => error_data}} = _event, _model)
      when is_map(error_data) do
    message = Map.get(error_data, "message", "Unknown streaming error from Ollama")
    raise RuntimeError, message: "Ollama streaming error: #{message}"
  end

  def decode_stream_event(event, model),
    do: ReqLLM.Providers.OpenAI.decode_stream_event(event, model)

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts), do: {opts, []}

  # ── Ollama-specific public API ─────────────────────────────────────

  @doc "Returns the Ollama OpenAI-compat base URL."
  def ollama_base_url do
    case Loomkin.Config.get_provider_endpoint(:ollama) do
      %{url: url} when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        "http://localhost:11434/v1"
    end
  end

  @doc "Returns the Ollama native API base URL (for /api/tags)."
  def ollama_api_url do
    ollama_base_url()
    |> String.split("/")
    |> Enum.slice(0..2)
    |> Enum.join("/")
  end

  @doc """
  Fetches the list of locally available Ollama models via `/api/tags`.
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

  @doc "Returns true if Ollama is reachable."
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

  defp auth_header do
    case Loomkin.Config.get_provider_endpoint(:ollama) do
      %{auth_key: key} when is_binary(key) and key != "" ->
        {"Authorization", "Bearer " <> key}

      _ ->
        {"Authorization", "Bearer ollama"}
    end
  end

  defp maybe_add_auth_header(request) do
    {name, value} = auth_header()
    Req.Request.put_header(request, name, value)
  end
end
