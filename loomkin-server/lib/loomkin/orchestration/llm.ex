defmodule Loomkin.Orchestration.LLM do
  @moduledoc """
  Thin shim over the underlying LLM provider.

  The orchestration framework calls into this behaviour so that reviewers and
  workers can be tested deterministically without hitting a real model. The
  production adapter (`Loomkin.Orchestration.LLM.ReqLLM`) routes to `req_llm`;
  the test adapter (`Loomkin.Orchestration.LLM.Stub`) returns scripted answers
  from an `Agent`.

  Adapter selection is per-call (via `:adapter` option) or via the
  `:loomkin, Loomkin.Orchestration, llm_adapter:` application env.
  """

  @type message :: %{role: :system | :user | :assistant, content: String.t()}

  @callback complete([message()], keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Resolves the configured adapter and calls `complete/2` on it.

  Options:

    * `:adapter` — override the configured adapter for this call
    * `:model` — passed through to the adapter (provider-specific id)
    * any other option — forwarded
  """
  @spec complete([message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts \\ []) do
    {adapter, opts} = Keyword.pop(opts, :adapter, configured_adapter())
    adapter.complete(messages, opts)
  end

  @doc "Returns the currently-configured default adapter."
  def configured_adapter do
    :loomkin
    |> Application.get_env(Loomkin.Orchestration, [])
    |> Keyword.get(:llm_adapter, Loomkin.Orchestration.LLM.ReqLLM)
  end
end
