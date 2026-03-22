defmodule Loomkin.Teams.ModelRouter do
  @moduledoc """
  Selects the model for each agent/task combination and handles opt-in escalation.

  ## Philosophy

  Loomkin's team architecture relies on fluid OTP communication, peer review, and
  knowledge routing to make every agent equally capable. Agents differ in their
  tools and system prompts, not their intelligence level. By default, every agent
  uses the same user-configured model.

  ## Model Selection Priority

  1. Task's `model_hint` — an explicit model string or legacy tier atom
  2. The user's configured default model (`[model].default` in `.loomkin.toml`)

  ## Escalation (Opt-in)

  Escalation only activates when `[teams.models].escalation` is configured in
  `.loomkin.toml` as an ordered list of model strings. When absent, `escalate/1`
  always returns `:disabled`.

  Example `.loomkin.toml`:

      [teams.models]
      escalation = ["zai:glm-5", "anthropic:claude-sonnet-4-6", "anthropic:claude-opus-4-6"]
  """

  @table :loomkin_model_router

  # Legacy tier names kept for backward-compatible hint resolution.
  # These are resolved dynamically via the user's configured default model.
  defp legacy_tier_models do
    default = Loomkin.Config.get(:model, :default) || fallback_model()

    fast =
      Loomkin.Config.get(:model, :fast) ||
        Application.get_env(:loomkin, :weak_model) ||
        default

    %{
      grunt: fast,
      standard: default,
      expert: default,
      architect: default
    }
  end

  defp fallback_model do
    Loomkin.Config.get(:model, :default) ||
      Application.get_env(:loomkin, :default_model)
  end

  # ── ETS initialization ───────────────────────────────────────────────

  @doc "Initialize the ETS table for failure/success tracking."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  # ── Failure tracking ─────────────────────────────────────────────────

  @doc "Record a failure for a specific agent/task combination."
  def record_failure(team_id, agent_name, task_id) do
    init_if_needed()
    key = {:failures, team_id, agent_name, task_id}

    try do
      :ets.update_counter(@table, key, 1)
    catch
      :error, :badarg ->
        # Key doesn't exist yet — initialize it
        :ets.insert(@table, {key, 1})
    end

    :ok
  end

  @doc """
  Check if escalation is warranted.

  ## Signatures

  - `should_escalate?(failure_count)` — simple integer check (threshold defaults to 2)
  - `should_escalate?(failure_count, threshold)` — simple integer check with custom threshold
  - `should_escalate?(team_id, agent_name, task_id)` — ETS-backed lookup (threshold defaults to 2)
  - `should_escalate?(team_id, agent_name, task_id, threshold)` — ETS-backed with custom threshold

  Note: This only checks whether the failure count meets the threshold.
  The caller should also check `escalation_enabled?/0` before actually escalating.
  """
  def should_escalate?(failure_count) when is_integer(failure_count) do
    failure_count >= 2
  end

  def should_escalate?(failure_count, threshold)
      when is_integer(failure_count) and is_integer(threshold) do
    failure_count >= threshold
  end

  def should_escalate?(team_id, agent_name, task_id) do
    should_escalate?(team_id, agent_name, task_id, 2)
  end

  def should_escalate?(team_id, agent_name, task_id, threshold) do
    init_if_needed()
    key = {:failures, team_id, agent_name, task_id}
    lookup_or_default(key, 0) >= threshold
  end

  @doc "Record a successful model invocation for an agent/task."
  def record_success(team_id, agent_name, task_id, model) do
    init_if_needed()

    # Per-agent success entry
    key = {:successes, team_id, agent_name, task_id}
    current = lookup_or_default(key, [])
    :ets.insert(@table, {key, [model | current]})

    # Aggregate model stats stored as {model_key, successes, attempts} — atomic update
    model_key = {:model_stats, model}

    try do
      # Increment both successes (pos 2) and attempts (pos 3) atomically
      :ets.update_counter(@table, model_key, [{2, 1}, {3, 1}])
    catch
      :error, :badarg ->
        :ets.insert(@table, {model_key, 1, 1})
    end

    :ok
  end

  @doc "Record a model attempt (called before the LLM request, paired with record_success on success)."
  def record_attempt(model) do
    init_if_needed()
    model_key = {:model_stats, model}

    try do
      # Stored as {model_key, successes, attempts} — increment attempts at position 3
      :ets.update_counter(@table, model_key, {3, 1})
    catch
      :error, :badarg ->
        :ets.insert(@table, {model_key, 0, 1})
    end

    :ok
  end

  @doc """
  Get the success rate for a model.

  Returns a float between 0.0 and 1.0. Returns 1.0 if no attempts have been
  recorded (optimistic default).
  """
  def get_success_rate(model) do
    init_if_needed()
    model_key = {:model_stats, model}

    case :ets.lookup(@table, model_key) do
      [{^model_key, _successes, 0}] -> 1.0
      [{^model_key, successes, attempts}] -> successes / attempts
      [] -> 1.0
    end
  end

  @doc "Get the current failure count for an agent/task."
  def get_failure_count(team_id, agent_name, task_id) do
    init_if_needed()
    key = {:failures, team_id, agent_name, task_id}
    lookup_or_default(key, 0)
  end

  @doc "Reset all tracking data for a team (call on team dissolve)."
  def reset_tracking(team_id) do
    init_if_needed()

    :ets.tab2list(@table)
    |> Enum.each(fn
      {{:failures, ^team_id, _, _}, _} = entry -> :ets.delete(@table, elem(entry, 0))
      {{:successes, ^team_id, _, _}, _} = entry -> :ets.delete(@table, elem(entry, 0))
      _ -> :ok
    end)

    :ok
  end

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Select the model for a given role and optional task.

  Every role uses the same user-configured default model. The only override
  is a task-level `model_hint`.

  Priority:
  1. Task's model_hint if present (explicit model string or legacy tier name)
  2. User's configured default model (`Loomkin.Config.get(:model, :default)`)
  """
  def select(_role, task \\ nil) do
    cond do
      task && task[:model_hint] -> resolve_hint(task[:model_hint])
      true -> default_model()
    end
  end

  @doc """
  Escalate to the next model in the configured escalation chain.

  Returns:
  - `{:ok, next_model}` if escalation is configured and a next model exists
  - `:max_reached` if the current model is the last in the chain
  - `:disabled` if escalation is not configured

  Escalation is opt-in. Configure it in `.loomkin.toml`:

      [teams.models]
      escalation = ["zai:glm-5", "anthropic:claude-sonnet-4-6", "anthropic:claude-opus-4-6"]
  """
  def escalate(current_model) do
    case configured_escalation_chain() do
      :disabled ->
        :disabled

      chain ->
        case Map.get(chain, current_model) do
          nil -> :max_reached
          next -> {:ok, next}
        end
    end
  end

  @doc "Check whether escalation is configured and enabled."
  def escalation_enabled? do
    configured_escalation_chain() != :disabled
  end

  @doc """
  Return the user's configured default model.

  Reads `[model].default` from `.loomkin.toml` via `Loomkin.Config`, falling back
  to the configured default if Config is not running or not set.
  """
  def default_model do
    case safe_config_get(:model, :default) do
      nil -> fallback_model()
      model when is_binary(model) -> model
      _ -> fallback_model()
    end
  end

  # ── Legacy compatibility ───────────────────────────────────────────────

  @doc """
  Return the configured model tiers (legacy).

  Kept for backward compatibility — reads `[teams.models]` from `.loomkin.toml`
  and merges with legacy tier defaults. New code should use `default_model/0`
  and `select/2` instead.
  """
  def configured_tiers do
    case safe_config_get(:teams, :models) do
      %{} = models ->
        Map.merge(legacy_tier_models(), atomize_tier_keys(models))

      _ ->
        legacy_tier_models()
    end
  end

  @doc """
  Build the escalation chain from the configured escalation list.

  Returns a map of `current_model => next_model` pairs, or `:disabled` if
  no escalation list is configured.

  When the legacy `[teams.models]` tier config is present but no explicit
  `escalation` list exists, escalation is disabled (not auto-inferred from tiers).
  """
  def configured_escalation_chain do
    case safe_config_get(:teams, :models) do
      %{escalation: chain} when is_list(chain) and length(chain) >= 2 ->
        build_chain_from_list(chain)

      %{"escalation" => chain} when is_list(chain) and length(chain) >= 2 ->
        build_chain_from_list(chain)

      _ ->
        :disabled
    end
  end

  @doc "Get the legacy tier for a model. Kept for backward compatibility."
  def tier_for_model(model) do
    tier_map =
      configured_tiers()
      |> Enum.map(fn {tier, m} -> {m, tier} end)
      |> Map.new()

    Map.get(tier_map, model, :standard)
  end

  @doc "List legacy model tier names. Kept for backward compatibility."
  def tiers, do: [:grunt, :standard, :expert, :architect]

  # ── Private ──────────────────────────────────────────────────────────

  defp resolve_hint(hint) when is_atom(hint) do
    # Legacy tier atom hint — check configured tiers first, fall back to legacy
    tiers = configured_tiers()
    Map.get(tiers, hint, default_model())
  end

  defp resolve_hint(hint) when is_binary(hint) do
    # Could be a legacy tier name string or a full model string
    tiers = configured_tiers()

    case hint do
      "grunt" -> Map.get(tiers, :grunt, default_model())
      "standard" -> Map.get(tiers, :standard, default_model())
      "expert" -> Map.get(tiers, :expert, default_model())
      "architect" -> Map.get(tiers, :architect, default_model())
      model_string -> model_string
    end
  end

  defp build_chain_from_list(models) when is_list(models) do
    models
    |> Enum.zip(Enum.drop(models, 1))
    |> Map.new()
  end

  defp init_if_needed do
    if :ets.whereis(@table) == :undefined do
      init()
    end
  end

  defp lookup_or_default(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp safe_config_get(key, subkey) do
    Loomkin.Config.get(key, subkey)
  rescue
    # Config GenServer may not be running (e.g. in tests)
    _ -> nil
  end

  defp atomize_tier_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        case k do
          "grunt" -> {:grunt, v}
          "standard" -> {:standard, v}
          "expert" -> {:expert, v}
          "architect" -> {:architect, v}
          _ -> {k, v}
        end

      {k, v} when is_atom(k) ->
        {k, v}
    end)
  end
end
