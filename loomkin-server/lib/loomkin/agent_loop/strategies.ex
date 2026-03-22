defmodule Loomkin.AgentLoop.Strategies do
  @moduledoc """
  Strategy dispatch for non-ReAct reasoning strategies.

  Bridges Loomkin's AgentLoop domain context (system prompt, model, rate limiting,
  event callbacks) into jido_ai's reasoning APIs. Non-ReAct strategies skip the
  tool loop entirely — they perform a single LLM reasoning pass and return the
  result, which is cheaper and faster for analysis-only agents.

  The existing ReAct path in AgentLoop.run/2 remains completely unchanged.
  """

  alias Loomkin.Telemetry, as: LoomkinTelemetry

  @type strategy :: :cot | :cod | :tot | :adaptive

  @doc """
  Run a non-ReAct reasoning strategy.

  Returns the same shape as `AgentLoop.run/2`:
  `{:ok, response_text, messages, metadata}` or `{:error, reason, messages}`.
  """
  @spec run(strategy(), [map()], map()) ::
          {:ok, String.t(), [map()], map()}
          | {:error, term(), [map()]}
  def run(strategy, messages, config) do
    :telemetry.execute(
      [:loomkin, :agent_loop, :strategy_selected],
      %{},
      %{
        strategy: strategy,
        agent_name: config.agent_name,
        team_id: config.team_id
      }
    )

    # Extract the latest user message as the prompt for reasoning
    prompt = extract_latest_prompt(messages)

    # For adaptive, resolve to a concrete strategy first
    {effective_strategy, complexity_score} = resolve_adaptive(strategy, prompt)

    system_prompt = build_strategy_system_prompt(effective_strategy, config.system_prompt)

    config.on_event.(:strategy_start, %{
      strategy: effective_strategy,
      original_strategy: strategy,
      complexity_score: complexity_score
    })

    # Check rate limiter before calling LLM
    {provider, _model_id} = parse_model(config.model)

    case maybe_acquire_rate_limit(config, provider) do
      :ok ->
        :ok

      {:wait, ms} ->
        Process.sleep(min(ms, 5_000))

        case maybe_acquire_rate_limit(config, provider) do
          :ok -> :ok
          {:wait, _} -> throw({:rate_limited, provider})
          {:budget_exceeded, scope} -> throw({:budget_exceeded, scope})
        end

      {:budget_exceeded, scope} ->
        throw({:budget_exceeded, scope})
    end

    telemetry_meta = %{
      session_id: config.session_id,
      model: config.model,
      strategy: effective_strategy
    }

    result =
      LoomkinTelemetry.span_llm_request(telemetry_meta, fn ->
        Jido.AI.generate_text(prompt,
          model: config.model,
          system_prompt: system_prompt,
          max_tokens: 4096,
          temperature: temperature_for(effective_strategy)
        )
      end)

    case result do
      {:ok, response} ->
        response_text = extract_text(response)
        usage = extract_usage(response)

        config.on_event.(:strategy_complete, %{
          strategy: effective_strategy,
          response_length: String.length(response_text)
        })

        assistant_msg = %{role: :assistant, content: response_text}
        updated_messages = messages ++ [assistant_msg]
        config.on_event.(:new_message, assistant_msg)

        {:ok, response_text, updated_messages, %{usage: usage}}

      {:error, reason} ->
        config.on_event.(:strategy_error, %{strategy: effective_strategy, error: inspect(reason)})
        {:error, reason, messages}
    end
  catch
    {:budget_exceeded, _scope} ->
      {:error, "Budget exceeded", messages}

    {:rate_limited, _provider} ->
      {:error, :rate_limited, messages}
  end

  # -- Strategy system prompt wrappers --

  defp build_strategy_system_prompt(:cot, base_prompt) do
    """
    #{base_prompt}

    ## Reasoning Mode: Chain-of-Thought
    Think step by step. Structure your response as:
    1. Break down the problem into clear steps
    2. Work through each step explicitly
    3. State your conclusion after the reasoning steps

    Separate your final answer with #### on its own line.
    """
  end

  defp build_strategy_system_prompt(:cod, base_prompt) do
    """
    #{base_prompt}

    ## Reasoning Mode: Chain-of-Draft
    Think step by step, but keep each intermediate step extremely concise:
    - Use minimal draft steps with at most 5 words per step when possible
    - Keep only the essential information needed to progress
    - Avoid verbose explanations during reasoning

    Provide your final answer after the separator ####.
    """
  end

  defp build_strategy_system_prompt(:tot, base_prompt) do
    """
    #{base_prompt}

    ## Reasoning Mode: Tree-of-Thoughts
    Explore multiple reasoning paths before committing to an answer:
    1. Generate 2-3 different approaches to the problem
    2. Evaluate each approach's strengths and weaknesses
    3. Select the best approach and explain why
    4. Provide your final answer based on the selected approach

    Separate your final answer with #### on its own line.
    """
  end

  # -- Adaptive resolution --

  defp resolve_adaptive(:adaptive, prompt) do
    {strategy, complexity_score, _task_type} =
      Jido.AI.Reasoning.Adaptive.Strategy.analyze_prompt(prompt)

    # Filter to strategies we actually support in Loomkin
    effective =
      case strategy do
        s when s in [:cot, :cod, :tot] -> s
        # Fall back to :cot for strategies we don't wrap yet (got, trm, aot)
        _ -> :cot
      end

    {effective, complexity_score}
  end

  defp resolve_adaptive(strategy, _prompt), do: {strategy, nil}

  # -- Temperature per strategy --

  defp temperature_for(:cot), do: 0.2
  defp temperature_for(:cod), do: 0.1
  defp temperature_for(:tot), do: 0.4

  # -- Helpers --

  defp extract_latest_prompt(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :user, content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp parse_model(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      _ -> {"zai", model_string}
    end
  end

  defp maybe_acquire_rate_limit(%{rate_limiter: nil}, _provider), do: :ok
  defp maybe_acquire_rate_limit(%{rate_limiter: callback}, provider), do: callback.(provider)

  defp extract_text(%ReqLLM.Response{} = response) do
    ReqLLM.Response.text(response) || ""
  end

  defp extract_text(response), do: Jido.AI.Turn.extract_text(response)

  defp extract_usage(%ReqLLM.Response{usage: usage}) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, :input_tokens, 0) || Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, :output_tokens, 0) || Map.get(usage, "output_tokens", 0),
      total_cost: Map.get(usage, :total_cost, 0) || 0
    }
  end

  defp extract_usage(response) when is_map(response) do
    usage =
      cond do
        is_map_key(response, :usage) -> Map.get(response, :usage, %{})
        is_map_key(response, "usage") -> Map.get(response, "usage", %{})
        true -> %{}
      end

    %{
      input_tokens: Map.get(usage, :input_tokens, 0) || Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, :output_tokens, 0) || Map.get(usage, "output_tokens", 0),
      total_cost: 0
    }
  end

  defp extract_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_cost: 0}
end
