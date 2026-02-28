defmodule Loom.Session.ContextWindow do
  @moduledoc "Builds a windowed message list that fits within the model's context limit."

  @default_context_limit 128_000
  @default_reserved_output 4096
  @chars_per_token 4

  @zone_defaults %{
    system_prompt: 2048,
    decision_context: 1024,
    repo_map: 2048,
    tool_definitions: 2048,
    reserved_output: 4096
  }

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
      system_prompt: @zone_defaults.system_prompt,
      decision_context: Keyword.get(opts, :max_decision_tokens, @zone_defaults.decision_context),
      repo_map: Keyword.get(opts, :max_repo_map_tokens, @zone_defaults.repo_map),
      tool_definitions: @zone_defaults.tool_definitions,
      reserved_output: Keyword.get(opts, :reserved_output, @zone_defaults.reserved_output)
    }

    zone_sum =
      zones.system_prompt + zones.decision_context + zones.repo_map +
        zones.tool_definitions + zones.reserved_output

    history = max(total - zone_sum, 0)

    Map.put(zones, :history, history)
  end

  @doc """
  Inject decision context into system prompt parts.

  Calls `Loom.Decisions.ContextBuilder.build/1` if available,
  otherwise returns system_parts unchanged.
  """
  @spec inject_decision_context([String.t()], String.t() | nil) :: [String.t()]
  def inject_decision_context(system_parts, nil), do: system_parts

  def inject_decision_context(system_parts, session_id) do
    # build/2 has a default arg, so Elixir generates build/1 as well — checking arity 1 is correct
    if Code.ensure_loaded?(Loom.Decisions.ContextBuilder) &&
         function_exported?(Loom.Decisions.ContextBuilder, :build, 1) do
      case Loom.Decisions.ContextBuilder.build(session_id) do
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

  Calls `Loom.RepoIntel.RepoMap.generate/2` if available,
  otherwise returns system_parts unchanged.
  """
  @spec inject_repo_map([String.t()], String.t() | nil, keyword()) :: [String.t()]
  def inject_repo_map(system_parts, project_path, opts \\ [])

  def inject_repo_map(system_parts, nil, _opts), do: system_parts

  def inject_repo_map(system_parts, project_path, opts) do
    if Code.ensure_loaded?(Loom.RepoIntel.RepoMap) &&
         function_exported?(Loom.RepoIntel.RepoMap, :generate, 2) do
      try do
        case Loom.RepoIntel.RepoMap.generate(project_path, opts) do
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

  Calls `Loom.ProjectRules.load/1` and `Loom.ProjectRules.format_for_prompt/1`
  if available, otherwise returns system_parts unchanged.
  """
  @spec inject_project_rules([String.t()], String.t() | nil) :: [String.t()]
  def inject_project_rules(system_parts, nil), do: system_parts

  def inject_project_rules(system_parts, project_path) do
    if Code.ensure_loaded?(Loom.ProjectRules) &&
         function_exported?(Loom.ProjectRules, :load, 1) do
      case Loom.ProjectRules.load(project_path) do
        {:ok, rules} ->
          formatted = Loom.ProjectRules.format_for_prompt(rules)

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

    # Build enriched system prompt
    system_parts = [system_prompt]
    system_parts = inject_decision_context(system_parts, session_id)
    system_parts = inject_repo_map(system_parts, project_path, max_tokens: budget.repo_map)
    system_parts = inject_project_rules(system_parts, project_path)
    enriched_system = Enum.join(system_parts, "\n\n")

    system_msg = %{role: :system, content: enriched_system}

    # Use explicit max_tokens if provided, otherwise compute from budget
    max_tokens = Keyword.get(opts, :max_tokens)
    reserved_output = Keyword.get(opts, :reserved_output, @default_reserved_output)

    available =
      if max_tokens do
        # Legacy path: explicit max_tokens overrides budget calculation
        system_tokens = estimate_tokens(enriched_system)
        max(max_tokens - system_tokens - reserved_output, 0)
      else
        # Budget-aware path: use the history allocation
        budget.history
      end

    recent_messages = select_recent(messages, available)

    messages_out = [system_msg | recent_messages]

    if opts[:team_id] do
      system_tokens = estimate_tokens(enriched_system)
      history_tokens = recent_messages |> Enum.map(&estimate_message_tokens/1) |> Enum.sum()
      total = model_limit(model)
      usage = (system_tokens + history_tokens) / total * 100

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

  Currently a placeholder that creates a brief text summary.
  Will be enhanced to call a weak model for actual summarization.
  """
  @spec summarize_old_messages([map()], keyword()) :: String.t()
  def summarize_old_messages(messages, _opts \\ []) do
    count = length(messages)

    snippet =
      messages
      |> Enum.map(&message_content/1)
      |> Enum.join(" ")
      |> String.slice(0, 200)

    "Summary of #{count} earlier messages: #{snippet}..."
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

  defp select_recent(messages, available_tokens) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {acc, used} ->
      msg_tokens = estimate_message_tokens(msg)

      if used + msg_tokens <= available_tokens do
        {:cont, {[msg | acc], used + msg_tokens}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
  end

  defp estimate_message_tokens(msg) do
    content_tokens = estimate_tokens(message_content(msg))
    # Add overhead for role, formatting
    content_tokens + 4
  end

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(_), do: ""
end
