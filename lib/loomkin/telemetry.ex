defmodule Loomkin.Telemetry do
  @moduledoc """
  Telemetry event definitions and emission helpers for Loomkin.

  Events:
  - `[:loomkin, :llm, :request, :start]` / `[:loomkin, :llm, :request, :stop]` / `[:loomkin, :llm, :request, :exception]`
  - `[:loomkin, :tool, :execute, :start]` / `[:loomkin, :tool, :execute, :stop]` / `[:loomkin, :tool, :execute, :exception]`
  - `[:loomkin, :session, :message]`
  - `[:loomkin, :decision, :logged]`
  - `[:loomkin, :agent, :lifecycle]`
  - `[:loomkin, :team, :spawn]`
  """

  @doc """
  Wraps an LLM request, emitting start/stop/exception telemetry events.

  Uses `:telemetry.span/3` for automatic duration tracking and exception handling.
  """
  def span_llm_request(metadata, fun) do
    :telemetry.span([:loomkin, :llm, :request], metadata, fn ->
      result = fun.()

      stop_meta =
        case result do
          {:ok, response} ->
            usage = extract_usage(response)
            Map.merge(metadata, usage)

          {:error, _reason} ->
            Map.put(metadata, :error, true)
        end

      {result, stop_meta}
    end)
  end

  @doc """
  Wraps a tool execution, emitting start/stop/exception telemetry events.

  Uses `:telemetry.span/3` for automatic duration tracking and exception handling.
  """
  def span_tool_execute(metadata, fun) do
    :telemetry.span([:loomkin, :tool, :execute], metadata, fn ->
      result = fun.()
      success = match?({:ok, _}, result) or is_binary(result)
      stop_meta = Map.merge(metadata, %{success: success})

      {result, stop_meta}
    end)
  end

  @doc "Emits a session message telemetry event."
  def emit_session_message(metadata) do
    :telemetry.execute(
      [:loomkin, :session, :message],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc "Emits a decision logged telemetry event."
  def emit_decision_logged(metadata) do
    :telemetry.execute(
      [:loomkin, :decision, :logged],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc "Emits an agent lifecycle telemetry event."
  def emit_agent_lifecycle(event, metadata) when event in [:init, :terminate, :state_change] do
    :telemetry.execute(
      [:loomkin, :agent, :lifecycle],
      %{system_time: System.system_time()},
      Map.put(metadata, :event, event)
    )
  end

  @doc "Emits a team spawn telemetry event."
  def emit_team_spawn(metadata) do
    :telemetry.execute(
      [:loomkin, :team, :spawn],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp extract_usage(%ReqLLM.Response{} = response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage ->
        %{
          input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
          output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0,
          total_cost: usage[:total_cost] || usage["total_cost"] || 0
        }

      _ ->
        %{input_tokens: 0, output_tokens: 0, total_cost: 0}
    end
  end

  defp extract_usage(_other) do
    %{input_tokens: 0, output_tokens: 0, total_cost: 0}
  end
end
