defmodule Loomkin.Orchestration.LLM.ReqLLM do
  @moduledoc """
  Production adapter that routes orchestration LLM calls through `ReqLLM`.

  ReqLLM expects messages in OpenAI-style `%{role: ..., content: ...}` shape;
  we pass ours through unchanged after normalizing keys.

  Returns `{:ok, text}` on success or `{:error, reason}` on failure. The
  reviewer parser is responsible for handling malformed output, not us.
  """
  @behaviour Loomkin.Orchestration.LLM

  @impl true
  def complete(messages, opts) do
    model = Keyword.get_lazy(opts, :model, &default_model/0)
    normalized = Enum.map(messages, &normalize/1)

    case ReqLLM.generate_text(model, normalized, Keyword.drop(opts, [:model, :adapter])) do
      {:ok, %{text: text}} when is_binary(text) ->
        {:ok, text}

      {:ok, %{content: text}} when is_binary(text) ->
        {:ok, text}

      {:ok, text} when is_binary(text) ->
        {:ok, text}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp default_model do
    :loomkin
    |> Application.get_env(Loomkin.Orchestration, [])
    |> Keyword.get(:default_model, "anthropic:claude-sonnet-4-5")
  end

  defp normalize(%{role: role, content: content}), do: %{role: to_string(role), content: content}
  defp normalize(other), do: other
end
