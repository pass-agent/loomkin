defmodule Loomkin.Session.ContextWindow do
  @moduledoc "Builds a windowed message list that fits within the model's context limit."

  @default_context_limit 128_000
  @default_reserved_output 4096
  @default_repo_map_tokens 2048
  @default_decision_context_tokens 1024
  @chars_per_token 4

  @doc """
  Allocate the token budget across zones for a given model.

  Returns a map with token allocations for each zone plus the remaining
  tokens available for conversation history.

  Options:
    - `:max_decision_tokens` - tokens for decision context (default 1024)
    - `:max_repo_map_tokens` - tokens for repo map (default 2048)
    - `:reserved_output` - tokens reserved for output (default 4096)
  """
  @spec allocate_budget(String.t() | nil, keyword()) :: map()
  def allocate_budget(model, opts \\ []) do
    total = model_limit(model)

    zones = %{
      system_prompt: 2048,
      decision_context: Keyword.get(opts, :max_decision_tokens, config_decision_context_tokens()),
      repo_map: Keyword.get(opts, :max_repo_map_tokens, config_repo_map_tokens()),
      tool_definitions: 2048,
      reserved_output: Keyword.get(opts, :reserved_output, config_reserved_output_tokens())
    }

    zone_sum =
      zones.system_prompt + zones.decision_context + zones.repo_map +
        zones.tool_definitions + zones.reserved_output

    history = max(total - zone_sum, 0)

    Map.put(zones, :history, history)
  end

  @doc """
  Inject decision context into system prompt parts.

  Calls `Loomkin.Decisions.ContextBuilder.build/1` if available,
  otherwise returns system_parts unchanged.
  """
  @spec inject_decision_context([String.t()], String.t() | nil) :: [String.t()]
  def inject_decision_context(system_parts, nil), do: system_parts

  def inject_decision_context(system_parts, session_id) do
    # build/2 has a default arg, so Elixir generates build/1 as well — checking arity 1 is correct
    if Code.ensure_loaded?(Loomkin.Decisions.ContextBuilder) &&
         function_exported?(Loomkin.Decisions.ContextBuilder, :build, 1) do
      case Loomkin.Decisions.ContextBuilder.build(session_id) do
        {:ok, context} when is_binary(context) and context != "" ->
          system_parts ++ [context]

        _ ->
          system_parts
      end
    else
      system_parts
    end
  end

  @doc """
  Inject repo map into system prompt parts.

  Calls `Loomkin.RepoIntel.RepoMap.generate/2` if available,
  otherwise returns system_parts unchanged.
  """
  @spec inject_repo_map([String.t()], String.t() | nil, keyword()) :: [String.t()]
  def inject_repo_map(system_parts, project_path, opts \\ [])

  def inject_repo_map(system_parts, nil, _opts), do: system_parts

  def inject_repo_map(system_parts, project_path, opts) do
    if Code.ensure_loaded?(Loomkin.RepoIntel.RepoMap) &&
         function_exported?(Loomkin.RepoIntel.RepoMap, :generate, 2) do
      try do
        case Loomkin.RepoIntel.RepoMap.generate(project_path, opts) do
          {:ok, repo_map} when is_binary(repo_map) and repo_map != "" ->
            system_parts ++ [repo_map]

          _ ->
            system_parts
        end
      catch
        :exit, _ -> system_parts
      end
    else
      system_parts
    end
  end

  @doc """
  Inject project rules into system prompt parts.

  Calls `Loomkin.ProjectRules.load/1` and `Loomkin.ProjectRules.format_for_prompt/1`
  if available, otherwise returns system_parts unchanged.
  """
  @spec inject_project_rules([String.t()], String.t() | nil) :: [String.t()]
  def inject_project_rules(system_parts, nil), do: system_parts

  def inject_project_rules(system_parts, project_path) do
    if Code.ensure_loaded?(Loomkin.ProjectRules) &&
         function_exported?(Loomkin.ProjectRules, :load, 1) do
      case Loomkin.ProjectRules.load(project_path) do
        {:ok, rules} ->
          formatted = Loomkin.ProjectRules.format_for_prompt(rules)

          if formatted != "" do
            system_parts ++ [formatted]
          else
            system_parts
          end

        _ ->
          system_parts
      end
    else
      system_parts
    end
  end

  @doc """
  Build a windowed message list that fits within the model's context limit.

  Takes a list of message maps, a system prompt string, and options.
  Returns a list of message maps: [system_msg | recent_history].

  Options:
    - `:model` - model string (e.g. "anthropic:claude-sonnet-4-6") for context limit lookup
    - `:max_tokens` - override the context limit
    - `:reserved_output` - tokens reserved for output (default 4096)
    - `:session_id` - session ID for decision context injection
    - `:project_path` - project path for repo map and rules injection
  """
  @spec build_messages([map()], String.t(), keyword()) :: [map()]
  def build_messages(messages, system_prompt, opts \\ []) do
    model = Keyword.get(opts, :model)
    session_id = Keyword.get(opts, :session_id)
    project_path = Keyword.get(opts, :project_path)

    budget = allocate_budget(model, opts)

    # Strip non-priority system messages from history to avoid sending multiple
    # system messages to the LLM. High-priority system messages (e.g. context
    # offload markers) stay in history so select_recent can retain them.
    {inline_system_msgs, history_messages} =
      Enum.split_with(messages, fn msg ->
        msg[:role] in [:system, "system"] and msg[:priority] != :high
      end)

    # Only keep the most recent inline system message (e.g. latest offload marker)
    # to prevent unbounded growth from accumulated system notices.
    latest_inline =
      case List.last(inline_system_msgs) do
        %{content: content} when is_binary(content) and content != "" -> content
        _ -> nil
      end

    # When using Anthropic OAuth, the token requires the system prompt to
    # start with the Claude Code identifier string. Prepend it here so all
    # code paths (agent loop, architect, conversational) get it automatically.
    system_prompt = maybe_prepend_oauth_identifier(system_prompt, model)

    # Build enriched system prompt
    system_parts = [system_prompt]
    system_parts = inject_decision_context(system_parts, session_id)
    system_parts = inject_repo_map(system_parts, project_path, max_tokens: budget.repo_map)
    system_parts = inject_project_rules(system_parts, project_path)
    system_parts = if latest_inline, do: system_parts ++ [latest_inline], else: system_parts

    enriched_system = Enum.join(system_parts, "\n\n")

    # Use explicit max_tokens if provided, otherwise compute from budget
    max_tokens = Keyword.get(opts, :max_tokens)
    reserved_output = Keyword.get(opts, :reserved_output, config_reserved_output_tokens())

    # Subtract the system prompt size from available budget so total stays within limits
    system_tokens = estimate_tokens(enriched_system)

    available =
      if max_tokens do
        max(max_tokens - system_tokens - reserved_output, 0)
      else
        # Budget-aware path: subtract system overage from history allocation
        max(budget.history - max(system_tokens - budget.system_prompt, 0), 0)
      end

    {recent_messages, evicted} = select_recent(history_messages, available)

    # Fold evicted message summary into the system prompt
    enriched_system =
      if evicted != [] do
        summary = summarize_old_messages(evicted, Keyword.take(opts, [:model]))

        if summary != "" do
          enriched_system <> "\n\n" <> summary
        else
          enriched_system
        end
      else
        enriched_system
      end

    system_msg = %{role: :system, content: enriched_system}
    messages_out = [system_msg | recent_messages]

    # Append context pressure as a trailing system message (preserves test contract)
    if opts[:team_id] do
      history_tokens = recent_messages |> Enum.map(&estimate_message_tokens/1) |> Enum.sum()
      total = model_limit(model)
      usage = (estimate_tokens(enriched_system) + history_tokens) / total * 100

      if usage > 50 do
        pressure_msg = %{
          role: :system,
          content:
            "[Context pressure: #{round(usage)}%]. Consider offloading completed topics via context_offload."
        }

        messages_out ++ [pressure_msg]
      else
        messages_out
      end
    else
      messages_out
    end
  end

  @doc """
  Summarize old messages that have been evicted from the context window.

  Calls a weak LLM model to produce a concise summary preserving key
  decisions, file paths, findings, and important context.
  Falls back to a text snippet on error.
  """
  @spec summarize_old_messages([map()], keyword()) :: String.t()
  def summarize_old_messages(messages, opts \\ [])

  def summarize_old_messages([], _opts), do: ""

  def summarize_old_messages(messages, opts) do
    count = length(messages)

    content =
      messages
      |> Enum.map(&message_content/1)
      |> Enum.join("\n")
      |> String.slice(0, 4000)

    model = Keyword.get(opts, :model) || weak_model()

    prompt = """
    Summarize the following #{count} conversation messages into a concise summary
    that preserves key decisions, file paths, findings, and important context.
    Keep it under 200 words.

    Messages:
    #{content}
    """

    case Loomkin.LLM.generate_text(model, [
           ReqLLM.Context.system("You are a concise summarizer. Preserve technical details."),
           ReqLLM.Context.user(prompt)
         ]) do
      {:ok, response} ->
        text = ReqLLM.Response.classify(response).text
        "[Summary of #{count} earlier messages]\n#{text}"

      {:error, _reason} ->
        snippet = String.slice(content, 0, 200)
        "Summary of #{count} earlier messages: #{snippet}..."
    end
  rescue
    _ ->
      snippet = messages |> Enum.map(&message_content/1) |> Enum.join(" ") |> String.slice(0, 200)
      "Summary of #{length(messages)} earlier messages: #{snippet}..."
  end

  @doc "Estimate token count for a string (rough: chars / 4)."
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0

  def estimate_tokens(text) when is_binary(text) do
    div(String.length(text), @chars_per_token)
  end

  @doc """
  Look up model context limit from LLMDB, fallback to 128,000.

  The model string format is "provider:model_name" (e.g. "anthropic:claude-sonnet-4-6").
  """
  @spec model_limit(String.t() | nil) :: pos_integer()
  def model_limit(nil), do: @default_context_limit

  def model_limit(model_string) when is_binary(model_string) do
    case LLMDB.model(model_string) do
      {:ok, %{limits: %{context: context}}} when is_integer(context) and context > 0 ->
        context

      _ ->
        @default_context_limit
    end
  end

  # Returns {kept_messages, evicted_messages} both in original order.
  # High-priority messages are always retained; evicted list excludes them.
  defp select_recent(messages, available_tokens) do
    indexed = Enum.with_index(messages)

    {high_indexed, normal_indexed} =
      Enum.split_with(indexed, fn {msg, _i} -> high_priority?(msg) end)

    high_tokens =
      high_indexed |> Enum.map(fn {msg, _} -> estimate_message_tokens(msg) end) |> Enum.sum()

    remaining_budget = max(available_tokens - high_tokens, 0)

    # Select normal messages newest-first within remaining budget
    kept_normal_indices =
      normal_indexed
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn {msg, idx}, {acc, used} ->
        msg_tokens = estimate_message_tokens(msg)

        if used + msg_tokens <= remaining_budget do
          {:cont, {[idx | acc], used + msg_tokens}}
        else
          {:halt, {acc, used}}
        end
      end)
      |> elem(0)
      |> MapSet.new()

    high_indices = high_indexed |> Enum.map(fn {_, i} -> i end) |> MapSet.new()
    selected_indices = MapSet.union(high_indices, kept_normal_indices)

    # Split into kept and evicted, both in original order.
    # Evicted = normal messages not selected (high-priority are never evicted).
    {kept, evicted} =
      Enum.reduce(indexed, {[], []}, fn {msg, i}, {kept_acc, evicted_acc} ->
        if MapSet.member?(selected_indices, i) do
          {[msg | kept_acc], evicted_acc}
        else
          {kept_acc, [msg | evicted_acc]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(evicted)}
  end

  defp high_priority?(%{priority: :high}), do: true
  defp high_priority?(_), do: false

  defp estimate_message_tokens(msg) do
    content_tokens = estimate_tokens(message_content(msg))
    # Add overhead for role, formatting
    content_tokens + 4
  end

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(_), do: ""

  @claude_code_identifier "You are Claude Code, Anthropic's official CLI for Claude."

  defp maybe_prepend_oauth_identifier(system_prompt, model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      ["anthropic", _model_id] ->
        if Loomkin.LLM.oauth_active?("anthropic") do
          @claude_code_identifier <> "\n\n" <> system_prompt
        else
          system_prompt
        end

      _ ->
        system_prompt
    end
  end

  defp maybe_prepend_oauth_identifier(system_prompt, _model), do: system_prompt

  defp weak_model do
    if Code.ensure_loaded?(Loomkin.Config) do
      try do
        Loomkin.Config.get(:model, :editor) || "zai:glm-4.5"
      rescue
        _ -> "zai:glm-4.5"
      end
    else
      "zai:glm-4.5"
    end
  end

  defp config_repo_map_tokens do
    Loomkin.Config.get(:context, :max_repo_map_tokens) || @default_repo_map_tokens
  end

  defp config_decision_context_tokens do
    Loomkin.Config.get(:context, :max_decision_context_tokens) || @default_decision_context_tokens
  end

  defp config_reserved_output_tokens do
    Loomkin.Config.get(:context, :reserved_output_tokens) || @default_reserved_output
  end
end
