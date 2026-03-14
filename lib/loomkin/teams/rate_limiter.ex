defmodule Loomkin.Teams.RateLimiter do
  @moduledoc "Token bucket rate limiter and budget tracker for team agents."

  use GenServer

  @default_bucket %{max: 50_000, refill_rate: 50_000}

  @default_team_budget 5.00
  @default_agent_budget 1.00

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Request permission to make an LLM call. Returns :ok or {:wait, milliseconds}."
  @spec acquire(String.t(), pos_integer()) :: :ok | {:wait, pos_integer()}
  def acquire(provider, estimated_tokens) do
    GenServer.call(__MODULE__, {:acquire, provider, estimated_tokens})
  end

  @doc "Record actual usage after an LLM call completes."
  @spec record_usage(String.t(), String.t(), map()) :: :ok | {:budget_exceeded, :team | :agent}
  def record_usage(team_id, agent_name, %{tokens: _, cost: _} = usage) do
    GenServer.call(__MODULE__, {:record_usage, team_id, agent_name, usage})
  end

  @doc "Get budget status for a team."
  @spec get_budget(String.t()) :: map()
  def get_budget(team_id) do
    GenServer.call(__MODULE__, {:get_budget, team_id})
  end

  @doc "Get budget status for a specific agent."
  @spec get_agent_budget(String.t(), String.t()) :: map()
  def get_agent_budget(team_id, agent_name) do
    GenServer.call(__MODULE__, {:get_agent_budget, team_id, agent_name})
  end

  @doc "Reset budget tracking for a team (used when team dissolves)."
  @spec reset_team(String.t()) :: :ok
  def reset_team(team_id) do
    GenServer.call(__MODULE__, {:reset_team, team_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    state = %{
      buckets: init_buckets(),
      teams: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, provider, estimated_tokens}, _from, state) do
    {bucket, state} = get_or_init_bucket(state, provider)
    bucket = refill(bucket)

    if bucket.tokens >= estimated_tokens do
      bucket = %{bucket | tokens: bucket.tokens - estimated_tokens}
      state = put_in(state, [:buckets, provider], bucket)
      {:reply, :ok, state}
    else
      deficit = estimated_tokens - bucket.tokens
      # refill_rate is tokens per minute; calculate ms to wait
      wait_ms = ceil(deficit / bucket.refill_rate * 60_000)
      wait_ms = max(wait_ms, 1)
      {:reply, {:wait, wait_ms}, state}
    end
  end

  def handle_call({:record_usage, team_id, agent_name, usage}, _from, state) do
    state = ensure_team(state, team_id, agent_name)
    team = state.teams[team_id]
    agent = team.agents[agent_name]

    new_agent = %{
      agent
      | spent: agent.spent + usage.cost,
        tokens_used: agent.tokens_used + usage.tokens
    }

    new_team = %{
      team
      | spent: team.spent + usage.cost,
        agents: Map.put(team.agents, agent_name, new_agent)
    }

    state = put_in(state, [:teams, team_id], new_team)

    reply =
      cond do
        new_team.spent >= new_team.limit -> {:budget_exceeded, :team}
        new_agent.spent >= new_agent.limit -> {:budget_exceeded, :agent}
        true -> :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:get_budget, team_id}, _from, state) do
    state = ensure_team(state, team_id)

    team = state.teams[team_id]

    result = %{
      spent: team.spent,
      limit: team.limit,
      remaining: team.limit - team.spent,
      agents:
        Map.new(team.agents, fn {name, agent} ->
          {name, %{spent: agent.spent, limit: agent.limit, tokens_used: agent.tokens_used}}
        end)
    }

    {:reply, result, state}
  end

  def handle_call({:get_agent_budget, team_id, agent_name}, _from, state) do
    state = ensure_team(state, team_id, agent_name)

    agent = state.teams[team_id].agents[agent_name]

    result = %{
      spent: agent.spent,
      limit: agent.limit,
      remaining: agent.limit - agent.spent,
      tokens_used: agent.tokens_used
    }

    {:reply, result, state}
  end

  def handle_call({:reset_team, team_id}, _from, state) do
    state = %{state | teams: Map.delete(state.teams, team_id)}
    {:reply, :ok, state}
  end

  # --- Internal ---

  defp init_buckets do
    now = System.monotonic_time(:millisecond)
    buckets = config_provider_buckets()

    Map.new(buckets, fn {provider, config} ->
      {provider,
       %{
         tokens: config.max,
         max: config.max,
         refill_rate: config.refill_rate,
         last_refill: now
       }}
    end)
  end

  defp get_or_init_bucket(state, provider) do
    configured = config_provider_buckets()

    case Map.fetch(state.buckets, provider) do
      {:ok, bucket} ->
        # Re-apply configured limits so settings changes take effect at runtime
        bucket =
          case Map.get(configured, provider) do
            %{max: max, refill_rate: rate} -> %{bucket | max: max, refill_rate: rate}
            nil -> bucket
          end

        state = put_in(state, [:buckets, provider], bucket)
        {bucket, state}

      :error ->
        now = System.monotonic_time(:millisecond)

        {max, rate} =
          case Map.get(configured, provider) do
            %{max: max, refill_rate: rate} -> {max, rate}
            nil -> {@default_bucket.max, @default_bucket.refill_rate}
          end

        bucket = %{tokens: max, max: max, refill_rate: rate, last_refill: now}
        state = put_in(state, [:buckets, provider], bucket)
        {bucket, state}
    end
  end

  defp refill(bucket) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - bucket.last_refill

    if elapsed_ms <= 0 do
      bucket
    else
      # refill_rate is tokens per minute
      tokens_to_add = elapsed_ms / 60_000 * bucket.refill_rate
      new_tokens = min(bucket.tokens + tokens_to_add, bucket.max)
      %{bucket | tokens: new_tokens, last_refill: now}
    end
  end

  defp ensure_team(state, team_id, agent_name \\ nil) do
    team_limit = budget_config(:max_per_team_usd, @default_team_budget)
    agent_limit = budget_config(:max_per_agent_usd, @default_agent_budget)

    state =
      if Map.has_key?(state.teams, team_id) do
        state
      else
        team = %{spent: 0.0, limit: team_limit, agents: %{}}
        put_in(state, [:teams, team_id], team)
      end

    if agent_name && !Map.has_key?(state.teams[team_id].agents, agent_name) do
      agent = %{spent: 0.0, limit: agent_limit, tokens_used: 0}
      put_in(state, [:teams, team_id, :agents, agent_name], agent)
    else
      state
    end
  end

  defp budget_config(key, default) do
    case Loomkin.Config.get(:teams, :budget) do
      %{} = budget -> Map.get(budget, key, default)
      _ -> default
    end
  end

  defp config_provider_buckets do
    anthropic =
      config_nested([:teams, :budget, :provider_limits, :anthropic_tokens_per_min], 80_000)

    openai = config_nested([:teams, :budget, :provider_limits, :openai_tokens_per_min], 90_000)
    google = config_nested([:teams, :budget, :provider_limits, :google_tokens_per_min], 60_000)

    %{
      "anthropic" => %{max: anthropic, refill_rate: anthropic},
      "openai" => %{max: openai, refill_rate: openai},
      "google" => %{max: google, refill_rate: google}
    }
  end

  defp config_nested(key_path, default) do
    get_in(Loomkin.Config.all(), key_path) || default
  end
end
