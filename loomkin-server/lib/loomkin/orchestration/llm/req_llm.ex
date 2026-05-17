defmodule Loomkin.Orchestration.LLM.ReqLLM do
  @moduledoc """
  Production adapter that routes orchestration LLM calls through `ReqLLM`.

  ReqLLM expects messages in OpenAI-style `%{role: ..., content: ...}` shape;
  we pass ours through unchanged after normalizing keys.

  Returns `{:ok, text}` on success or `{:error, reason}` on failure. The
  reviewer parser is responsible for handling malformed output, not us.

  ## Cost attribution telemetry

  Before invoking the provider, the adapter seeds
  `Process.put(:loomkin_epic_id, epic_id)` from `opts[:epic_id]` when present.
  After the call (success or failure), it emits the
  `[:loomkin, :orchestration, :llm, :request, :stop]` telemetry event with:

      measurements = %{
        duration_ms: integer(),
        input_tokens: non_neg_integer(),
        output_tokens: non_neg_integer()
      }

      meta = %{
        epic_id: binary() | nil,
        model: String.t(),
        status: :ok | :error
      }

  `Loomkin.Orchestration.CostTracker` attaches to that event and persists a
  per-call `orchestration_cost_events` row.
  """
  @behaviour Loomkin.Orchestration.LLM

  @impl true
  def complete(messages, opts) do
    model = Keyword.get_lazy(opts, :model, &default_model/0)
    normalized = Enum.map(messages, &normalize/1)
    epic_id = Keyword.get(opts, :epic_id)
    if is_binary(epic_id), do: Process.put(:loomkin_epic_id, epic_id)

    started_at = System.monotonic_time(:millisecond)
    forward_opts = Keyword.drop(opts, [:model, :adapter, :epic_id])

    {result, usage} =
      case ReqLLM.generate_text(model, normalized, forward_opts) do
        {:ok, %{text: text} = response} when is_binary(text) ->
          {{:ok, text}, extract_usage(response)}

        {:ok, %{content: text} = response} when is_binary(text) ->
          {{:ok, text}, extract_usage(response)}

        {:ok, text} when is_binary(text) ->
          {{:ok, text}, %{}}

        {:ok, other} ->
          {{:error, {:unexpected_response, other}}, extract_usage(other)}

        {:error, _} = err ->
          {err, %{}}
      end

    duration_ms = max(System.monotonic_time(:millisecond) - started_at, 0)
    emit_telemetry(epic_id || Process.get(:loomkin_epic_id), model, usage, duration_ms, result)

    result
  rescue
    e ->
      duration_ms = 0

      emit_telemetry(
        Process.get(:loomkin_epic_id),
        Keyword.get(opts, :model) || try_default_model(),
        %{},
        duration_ms,
        {:error, Exception.message(e)}
      )

      {:error, Exception.message(e)}
  end

  defp default_model do
    :loomkin
    |> Application.get_env(Loomkin.Orchestration, [])
    |> Keyword.get(:default_model, "anthropic:claude-sonnet-4-5")
  end

  defp try_default_model do
    default_model()
  rescue
    _ -> nil
  end

  defp emit_telemetry(epic_id, model, usage, duration_ms, result) do
    status =
      case result do
        {:ok, _} -> :ok
        _ -> :error
      end

    :telemetry.execute(
      [:loomkin, :orchestration, :llm, :request, :stop],
      %{
        duration_ms: duration_ms,
        input_tokens: usage[:input_tokens] || 0,
        output_tokens: usage[:output_tokens] || 0
      },
      %{
        epic_id: epic_id,
        model: to_string_or_nil(model),
        status: status
      }
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ReqLLM responses may carry usage in a few shapes; we extract a normalized
  # %{input_tokens, output_tokens} when we can find it, or %{} when we can't.
  defp extract_usage(%{usage: usage}) when is_map(usage) do
    %{
      input_tokens: usage[:input_tokens] || usage["input_tokens"] || usage[:prompt_tokens] || 0,
      output_tokens:
        usage[:output_tokens] || usage["output_tokens"] || usage[:completion_tokens] || 0
    }
  end

  defp extract_usage(%{"usage" => usage}) when is_map(usage), do: extract_usage(%{usage: usage})
  defp extract_usage(_), do: %{}

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v) when is_binary(v), do: v
  defp to_string_or_nil(v), do: to_string(v)

  defp normalize(%{role: role, content: content}), do: %{role: to_string(role), content: content}
  defp normalize(other), do: other
end
