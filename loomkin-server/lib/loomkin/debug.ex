defmodule Loomkin.Debug do
  require Logger

  @moduledoc """
  Pre-built debugging helpers for runtime introspection via Tidewave's `project_eval` MCP tool.

  This module is NOT for production use. It provides zero-overhead helpers that make it easy
  to inspect agent state, team health, ETS tables, PubSub topics, and telemetry handlers
  from a live REPL session without permanent logging.

  ## Usage (via Tidewave project_eval)

      Loomkin.Debug.all_agents()
      Loomkin.Debug.agent_state("team_abc", "concierge")
      Loomkin.Debug.team_state("team_abc")
      Loomkin.Debug.ets_summary()
      Loomkin.Debug.pubsub_topics()

  """

  alias Loomkin.Teams.Context
  alias Loomkin.Teams.CostTracker

  @registry Loomkin.Teams.AgentRegistry
  @pubsub Loomkin.PubSub

  # --- Agent Inspection ---

  @doc """
  Get the full GenServer state for a specific agent.

  Uses `:sys.get_state/2` with a 30-second timeout. Returns `{:error, :not_found}`
  if the agent is not registered, or `{:error, reason}` on timeout/failure.
  """
  def agent_state(team_id, agent_name) when is_binary(team_id) and is_binary(agent_name) do
    case Registry.lookup(@registry, {team_id, agent_name}) do
      [{pid, _meta}] ->
        {:ok, :sys.get_state(pid, 30_000)}

      [] ->
        {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Get process health info for a specific agent: message_queue_len, memory,
  reductions, status, and current_function.
  """
  def agent_health(team_id, agent_name) when is_binary(team_id) and is_binary(agent_name) do
    case Registry.lookup(@registry, {team_id, agent_name}) do
      [{pid, _meta}] ->
        info_keys = [:message_queue_len, :memory, :reductions, :status, :current_function]

        case Process.info(pid, info_keys) do
          nil -> {:error, :process_dead}
          info -> {:ok, Map.new(info)}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  List all entries in the AgentRegistry.

  Returns a list of `%{key: {team_id, name}, pid: pid, meta: meta}` for every
  registered process, including non-agent entries (keepers, bridges, etc.).
  """
  def all_agents do
    Registry.select(@registry, [
      {{:"$1", :"$2", :"$3"}, [], [%{key: :"$1", pid: :"$2", meta: :"$3"}]}
    ])
  rescue
    ArgumentError -> []
  end

  @doc """
  List agents registered under a specific team_id.

  Filters `all_agents/0` to entries whose key is a `{team_id, name}` tuple
  matching the given team_id.
  """
  def team_agents(team_id) when is_binary(team_id) do
    all_agents()
    |> Enum.filter(fn
      %{key: {^team_id, _name}} -> true
      _ -> false
    end)
  end

  # --- Queue/Load Visibility ---

  @doc """
  Show message queue depth and memory for each agent in a team.

  Returns a list of `%{name: name, message_queue_len: n, memory: bytes}` sorted
  by queue depth descending — useful for spotting overloaded agents.
  """
  def agent_queue_depths(team_id) when is_binary(team_id) do
    team_agents(team_id)
    |> Enum.map(fn %{key: {_team_id, name}, pid: pid} ->
      case Process.info(pid, [:message_queue_len, :memory]) do
        nil ->
          %{name: name, message_queue_len: -1, memory: 0, alive: false}

        info ->
          %{
            name: name,
            message_queue_len: info[:message_queue_len],
            memory: info[:memory],
            alive: true
          }
      end
    end)
    |> Enum.sort_by(& &1.message_queue_len, :desc)
  end

  # --- Team State ---

  @doc """
  Get a combined snapshot of team state from ETS: agents, discoveries, and claims.

  Returns a map with the raw lists plus counts for quick inspection.
  """
  def team_state(team_id) when is_binary(team_id) do
    agents = Context.list_agents(team_id)
    discoveries = Context.list_discoveries(team_id)
    claims = Context.list_all_claims(team_id)

    %{
      agents: agents,
      agent_count: length(agents),
      discoveries: discoveries,
      discovery_count: length(discoveries),
      claims: claims,
      claim_count: length(claims)
    }
  end

  @doc """
  Get aggregated cost data for all agents in a team via CostTracker.

  Returns a map of `agent_name => %{input_tokens, output_tokens, cost, requests, last_model}`.
  """
  def team_costs(team_id) when is_binary(team_id) do
    CostTracker.get_team_usage(team_id)
  end

  # --- Telemetry Helpers ---

  @doc """
  Attach a temporary telemetry handler that IO.inspects events matching `event_name`.

  Returns the handler ID string which can be passed to `detach_debug/1`.

  ## Example

      id = Loomkin.Debug.attach_debug([:loomkin, :llm, :request, :stop])
      # ... trigger some LLM calls ...
      Loomkin.Debug.detach_debug(id)

  """
  def attach_debug(event_name, label \\ "DBG") when is_list(event_name) and is_binary(label) do
    id = "debug-#{label}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      event_name,
      fn event, measurements, metadata, _config ->
        Logger.debug(
          "[#{label}] #{inspect(%{event: event, measurements: measurements, metadata: metadata}, limit: :infinity, printable_limit: 4096)}"
        )
      end,
      nil
    )

    id
  end

  @doc "Detach a debug telemetry handler by its ID."
  def detach_debug(id) when is_binary(id) do
    :telemetry.detach(id)
  end

  @doc """
  List all attached telemetry handlers whose event name starts with the given prefix.

  Defaults to `[:loomkin]` to show all Loomkin-related handlers.
  """
  def telemetry_handlers(prefix \\ [:loomkin]) when is_list(prefix) do
    :telemetry.list_handlers(prefix)
  end

  # --- Logger Helpers ---

  @doc """
  Enable `:debug` level logging for a specific module.

  Useful for temporarily increasing verbosity on a single module without
  changing the global logger level.

      Loomkin.Debug.enable_verbose(Loomkin.Teams.Agent)

  """
  def enable_verbose(module) when is_atom(module) do
    Logger.put_module_level(module, :debug)
  end

  @doc """
  Reset module-level logging override, reverting to the global logger level.

      Loomkin.Debug.disable_verbose(Loomkin.Teams.Agent)

  """
  def disable_verbose(module) when is_atom(module) do
    Logger.delete_module_level(module)
  end

  # --- ETS Inspection ---

  @doc """
  List the top 20 ETS tables by memory usage.

  Returns a list of `%{name: name, id: ref, size: rows, memory_bytes: bytes, type: type}`.
  """
  def ets_summary do
    :ets.all()
    |> Enum.map(fn table ->
      try do
        info = :ets.info(table)

        %{
          name: info[:name],
          id: info[:id],
          size: info[:size],
          memory_bytes: info[:memory] * :erlang.system_info(:wordsize),
          type: info[:type]
        }
      rescue
        ArgumentError -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory_bytes, :desc)
    |> Enum.take(20)
  end

  # --- PubSub Inspection ---

  @doc """
  List active PubSub topics and their subscriber counts.

  Phoenix.PubSub uses a partitioned `Registry` (`:duplicate` keys) under the hood.
  This function queries the Registry partitions to aggregate topics and their
  subscriber counts.

  Returns a list of `%{topic: topic, subscriber_count: n}` sorted by subscriber
  count descending.
  """
  def pubsub_topics do
    Registry.select(@pubsub, [
      {{:"$1", :"$2", :"$3"}, [], [:"$1"]}
    ])
    |> Enum.frequencies()
    |> Enum.map(fn {topic, count} -> %{topic: topic, subscriber_count: count} end)
    |> Enum.sort_by(& &1.subscriber_count, :desc)
  rescue
    ArgumentError -> {:error, :pubsub_not_running}
  end
end
