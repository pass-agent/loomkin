defmodule Loomkin.Orchestration.LLM.Stub do
  @moduledoc """
  Test adapter for `Loomkin.Orchestration.LLM`.

  Backed by an `Agent` of scripted responses. Tests register a queue of
  responses (matched by reviewer name or in FIFO order) and the adapter pops
  them off as `complete/2` is called.

  Usage:

      {:ok, _} = Loomkin.Orchestration.LLM.Stub.start_link()
      Loomkin.Orchestration.LLM.Stub.queue([
        {:by_reviewer, :feasibility, ~s({"verdict":"pass","evidence":["x:1"]})},
        {:fifo, ~s({"verdict":"fail","blocking":["x"],"evidence":["x:1"]})}
      ])
      Application.put_env(:loomkin, Loomkin.Orchestration,
        llm_adapter: Loomkin.Orchestration.LLM.Stub)
  """
  @behaviour Loomkin.Orchestration.LLM

  use Agent

  @name __MODULE__

  def start_link(_ \\ []) do
    Agent.start_link(fn -> %{queue: [], default: nil} end, name: @name)
  end

  @doc """
  Queue scripted responses. Each item is one of:

    * `{:by_reviewer, reviewer_name :: atom(), text :: String.t()}` — matched
      when `opts[:reviewer]` equals `reviewer_name`
    * `{:fifo, text :: String.t()}` — pulled in order when no by-reviewer match
    * `text :: String.t()` — sugar for `{:fifo, text}`
  """
  def queue(responses) when is_list(responses) do
    Agent.update(@name, fn s -> %{s | queue: s.queue ++ Enum.map(responses, &normalize/1)} end)
  end

  defp normalize({:by_reviewer, _, _} = entry), do: entry
  defp normalize({:fifo, text}) when is_binary(text), do: {:fifo, text}
  defp normalize(text) when is_binary(text), do: {:fifo, text}

  @doc "Set a default response returned when the queue is empty."
  def default(text) when is_binary(text) do
    Agent.update(@name, fn s -> %{s | default: text} end)
  end

  @doc "Reset queue + default."
  def reset, do: Agent.update(@name, fn _ -> %{queue: [], default: nil} end)

  @impl true
  def complete(_messages, opts) do
    reviewer = Keyword.get(opts, :reviewer)

    case pop(reviewer) do
      nil -> {:error, :no_stub_response}
      text -> {:ok, text}
    end
  end

  @doc "Snapshot the queue. Useful for diagnostics."
  def dump_queue, do: Agent.get(@name, & &1)

  defp pop(reviewer) do
    Agent.get_and_update(@name, fn s ->
      case extract(s.queue, reviewer) do
        {nil, rest} -> {s.default, %{s | queue: rest}}
        {text, rest} -> {text, %{s | queue: rest}}
      end
    end)
  end

  # First try by-reviewer match, otherwise pop the first FIFO entry.
  defp extract(queue, reviewer) do
    case Enum.split_with(queue, &match?({:by_reviewer, ^reviewer, _}, &1)) do
      {[{:by_reviewer, ^reviewer, text} | extras], rest} ->
        {text, extras ++ rest}

      {[], _} ->
        case Enum.split_while(queue, fn
               {:by_reviewer, _, _} -> true
               _ -> false
             end) do
          {leading, [{:fifo, text} | tail]} -> {text, leading ++ tail}
          {_, []} -> {nil, queue}
        end
    end
  end
end
