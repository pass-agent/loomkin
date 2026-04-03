defmodule Loomkin.LLMRetry do
  @moduledoc """
  Retry wrapper for LLM calls with exponential backoff.

  Classifies errors as transient (retry) vs permanent (fail immediately).
  Broadcasts retry status via the provided callback for UI visibility.
  """

  @default_max_retries 3
  @base_backoff_ms 1_000

  @doc """
  Wrap an LLM call with retry logic.

  ## Options

    * `:max_retries` - maximum retry attempts (default #{@default_max_retries})
    * `:on_retry` - `fn attempt, reason, backoff_ms -> :ok end` callback for retry events

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec with_retry(keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_retry(opts \\ [], fun) do
    max_retries = Keyword.get(opts, :max_retries, max_retries())
    on_retry = Keyword.get(opts, :on_retry, fn _attempt, _reason, _ms -> :ok end)
    do_retry(fun, on_retry, max_retries, 0)
  end

  defp max_retries do
    Loomkin.Config.get(:agents, :llm_max_retries) || @default_max_retries
  end

  defp base_backoff_ms do
    Loomkin.Config.get(:agents, :llm_base_backoff_ms) || @base_backoff_ms
  end

  defp do_retry(_fun, _on_retry, max_retries, attempt) when attempt > max_retries do
    {:error, :max_retries_exhausted}
  end

  defp do_retry(fun, on_retry, max_retries, attempt) do
    case fun.() do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        if transient?(reason) and attempt < max_retries do
          backoff_ms = Integer.pow(2, attempt) * base_backoff_ms()
          on_retry.(attempt + 1, reason, backoff_ms)
          Process.sleep(backoff_ms)
          do_retry(fun, on_retry, max_retries, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Returns true if the error is transient and should be retried.

  Transient errors: rate limits, timeouts, 5xx server errors, connection errors.
  Permanent errors: auth failures, invalid requests, model not found.
  """
  def transient?(reason) do
    cond do
      is_binary(reason) ->
        transient_string?(reason)

      is_struct(reason) ->
        status = Map.get(reason, :status)
        reason_field = Map.get(reason, :reason)
        message = reason_field || Map.get(reason, :message) || ""

        cond do
          status in [429, 500, 502, 503, 504, 529] ->
            true

          status in [400, 401, 403, 404] ->
            false

          is_atom(reason_field) ->
            reason_field in [
              :timeout,
              :closed,
              :econnrefused,
              :econnreset,
              :econnaborted,
              :ehostunreach
            ]

          is_binary(message) ->
            transient_string?(message)

          true ->
            false
        end

      is_map(reason) ->
        status = reason[:status] || reason["status"]
        message = reason[:reason] || reason[:message] || reason["message"] || ""

        cond do
          status in [429, 500, 502, 503, 504, 529] -> true
          status in [400, 401, 403, 404] -> false
          is_binary(message) -> transient_string?(message)
          true -> false
        end

      is_atom(reason) ->
        reason in [:timeout, :econnrefused, :econnreset, :closed, :nxdomain]

      true ->
        false
    end
  end

  defp transient_string?(msg) do
    lower = String.downcase(msg)

    String.contains?(lower, "timeout") or
      String.contains?(lower, "rate limit") or
      String.contains?(lower, "overloaded") or
      String.contains?(lower, "temporarily") or
      String.contains?(lower, "503") or
      String.contains?(lower, "502") or
      String.contains?(lower, "429") or
      String.contains?(lower, "connection") or
      String.contains?(lower, "econnrefused") or
      String.contains?(lower, "econnreset")
  end
end
