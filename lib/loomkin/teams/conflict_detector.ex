defmodule Loomkin.Teams.ConflictDetector do
  @moduledoc """
  Per-team GenServer that watches for conflicts between agents.

  Detects three types of conflicts:
  - **File-level**: Two agents editing the same file (beyond claim_region)
  - **Approach**: Tasks with contradictory descriptions targeting the same area
  - **Decision**: Contradictory decision nodes on the same topic

  On conflict detection, broadcasts `{:conflict_detected, details}` to the team
  and injects warnings into both agents' message streams.
  """

  use GenServer

  require Logger

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.Comms

  @pubsub Loomkin.PubSub

  # Actions that indicate modification intent
  @modify_actions ~w(add create write implement build)
  @remove_actions ~w(remove delete drop deprecate)
  @change_actions ~w(change refactor rename move migrate replace update rewrite)

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    GenServer.start_link(__MODULE__, opts, name: via(team_id))
  end

  defp via(team_id) do
    {:via, Registry, {Loomkin.Teams.AgentRegistry, {:conflict_detector, team_id}}}
  end

  @doc "Check two task descriptions for approach conflicts. Returns nil or a conflict description."
  @spec check_approach_conflict(String.t(), String.t(), String.t(), String.t()) :: String.t() | nil
  def check_approach_conflict(desc_a, desc_b, agent_a \\ "agent_a", agent_b \\ "agent_b") do
    intent_a = extract_intent(desc_a)
    intent_b = extract_intent(desc_b)

    targets_a = extract_targets(desc_a)
    targets_b = extract_targets(desc_b)

    shared_targets = MapSet.intersection(targets_a, targets_b)

    if MapSet.size(shared_targets) > 0 and contradictory_intents?(intent_a, intent_b) do
      targets_str = shared_targets |> MapSet.to_list() |> Enum.join(", ")
      "#{agent_a} (#{intent_a}) vs #{agent_b} (#{intent_b}) on: #{targets_str}"
    else
      nil
    end
  end

  @doc "Extract action intent from a task description."
  @spec extract_intent(String.t()) :: String.t()
  def extract_intent(description) do
    words = description |> String.downcase() |> String.split(~r/[\s,;]+/)

    cond do
      Enum.any?(words, &(&1 in @remove_actions)) -> "remove"
      Enum.any?(words, &(&1 in @modify_actions)) -> "add"
      Enum.any?(words, &(&1 in @change_actions)) -> "change"
      true -> "unknown"
    end
  end

  @doc "Extract target identifiers (file paths, module names, function names) from text."
  @spec extract_targets(String.t()) :: MapSet.t()
  def extract_targets(text) do
    # Match file paths (e.g., lib/foo/bar.ex, test/thing_test.exs)
    file_paths =
      Regex.scan(~r/(?:lib|test|config)\/[\w\/]+\.(?:exs?|eex|json|toml|ya?ml)/, text)
      |> List.flatten()

    # Match module-like references (CamelCase.Words)
    modules =
      Regex.scan(~r/[A-Z][a-z]+(?:\.[A-Z][a-z]+)+/, text)
      |> List.flatten()

    # Match function-like references (snake_case with optional module prefix)
    functions =
      Regex.scan(~r/(?:[A-Z]\w+\.)?[a-z_]\w+\/\d/, text)
      |> List.flatten()

    MapSet.new(file_paths ++ modules ++ functions)
  end

  @doc "Check if two intents are contradictory (e.g., add vs remove)."
  @spec contradictory_intents?(String.t(), String.t()) :: boolean()
  def contradictory_intents?("add", "remove"), do: true
  def contradictory_intents?("remove", "add"), do: true
  def contradictory_intents?("add", "change"), do: false
  def contradictory_intents?("change", "add"), do: false
  def contradictory_intents?("remove", "change"), do: true
  def contradictory_intents?("change", "remove"), do: true
  def contradictory_intents?(_, _), do: false

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)

    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}")
    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}:tasks")
    Phoenix.PubSub.subscribe(@pubsub, "team:#{team_id}:decisions")

    state = %{
      team_id: team_id,
      # Track which agents are editing which files: %{file_path => [{agent_name, timestamp}]}
      file_edits: %{},
      # Recent task descriptions: %{task_id => %{owner: _, description: _, title: _}}
      active_tasks: %{},
      # Recent conflicts to avoid duplicate alerts: MapSet of conflict keys
      seen_conflicts: MapSet.new()
    }

    Logger.info("[ConflictDetector] Started for team #{team_id}")
    {:ok, state}
  end

  # --- File edit tracking ---

  # AgentLoop emits {:tool_executing, agent_name, %{tool_name: name, tool_target: path}}
  # and {:tool_complete, agent_name, %{tool_name: name, result: text}}
  @impl true
  def handle_info({:tool_executing, agent_name, %{tool_name: tool, tool_target: file_path}}, state)
      when tool in ["file_write", "file_edit"] do
    if file_path && file_path != "*" do
      state = track_file_edit(state, to_string(agent_name), file_path)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tool_complete, _agent_name, %{tool_name: tool}}, state)
      when tool in ["file_write", "file_edit"] do
    # tool_complete doesn't carry file_path, but tool_executing already tracked it
    {:noreply, state}
  end

  # --- Task tracking ---

  @impl true
  def handle_info({:task_assigned, task_id, agent_name}, state) do
    case Loomkin.Teams.Tasks.get_task(task_id) do
      {:ok, task} ->
        task_info = %{
          owner: to_string(agent_name),
          description: task.description || task.title,
          title: task.title
        }

        state = put_in(state.active_tasks[task_id], task_info)
        state = check_task_conflicts(state, task_id, task_info)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_completed, task_id, _owner, _result}, state) do
    state = %{state | active_tasks: Map.delete(state.active_tasks, task_id)}
    {:noreply, state}
  end

  @impl true
  def handle_info({:task_failed, task_id, _owner, _reason}, state) do
    state = %{state | active_tasks: Map.delete(state.active_tasks, task_id)}
    {:noreply, state}
  end

  # --- Decision graph watching ---

  @impl true
  def handle_info({:decision_logged, node_id, _agent_name}, state) do
    state = check_decision_conflict(state, node_id)
    {:noreply, state}
  end

  # Catch-all
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private: File conflict detection ---

  defp track_file_edit(state, agent_name, file_path) do
    now = System.monotonic_time(:millisecond)

    editors =
      Map.get(state.file_edits, file_path, [])
      # Expire entries older than 5 minutes
      |> Enum.filter(fn {_name, ts} -> now - ts < 300_000 end)
      # Remove stale entry from same agent before re-adding
      |> Enum.reject(fn {name, _ts} -> name == agent_name end)

    # Check for conflict with other editors
    other_editors = Enum.map(editors, fn {name, _ts} -> name end) |> Enum.uniq()

    Enum.each(other_editors, fn other_agent ->
      conflict_key = file_conflict_key(agent_name, other_agent, file_path)

      if not MapSet.member?(state.seen_conflicts, conflict_key) do
        broadcast_conflict(state.team_id, %{
          type: :file_conflict,
          agent_a: agent_name,
          agent_b: other_agent,
          description: "Both agents editing #{file_path}"
        })
      end
    end)

    updated_editors = [{agent_name, now} | editors]
    file_edits = Map.put(state.file_edits, file_path, updated_editors)

    # Mark conflicts as seen
    new_seen =
      Enum.reduce(other_editors, state.seen_conflicts, fn other, acc ->
        MapSet.put(acc, file_conflict_key(agent_name, other, file_path))
      end)

    %{state | file_edits: file_edits, seen_conflicts: new_seen}
  end

  defp file_conflict_key(a, b, path) do
    [a, b] = Enum.sort([a, b])
    {:file, a, b, path}
  end

  # --- Private: Task approach conflict detection ---

  defp check_task_conflicts(state, new_task_id, new_task_info) do
    conflicts =
      state.active_tasks
      |> Enum.reject(fn {id, _info} -> id == new_task_id end)
      |> Enum.filter(fn {_id, info} -> info.owner != new_task_info.owner end)
      |> Enum.reduce([], fn {_other_id, other_info}, acc ->
        case check_approach_conflict(
               new_task_info.description,
               other_info.description,
               new_task_info.owner,
               other_info.owner
             ) do
          nil -> acc
          desc -> [{new_task_info.owner, other_info.owner, desc} | acc]
        end
      end)

    Enum.each(conflicts, fn {agent_a, agent_b, desc} ->
      conflict_key = approach_conflict_key(agent_a, agent_b, desc)

      if not MapSet.member?(state.seen_conflicts, conflict_key) do
        broadcast_conflict(state.team_id, %{
          type: :approach_conflict,
          agent_a: agent_a,
          agent_b: agent_b,
          description: desc
        })
      end
    end)

    new_seen =
      Enum.reduce(conflicts, state.seen_conflicts, fn {a, b, desc}, acc ->
        MapSet.put(acc, approach_conflict_key(a, b, desc))
      end)

    %{state | seen_conflicts: new_seen}
  end

  defp approach_conflict_key(a, b, desc) do
    [a, b] = Enum.sort([a, b])
    {:approach, a, b, desc}
  end

  # --- Private: Decision conflict detection ---

  defp check_decision_conflict(state, node_id) do
    case Graph.get_node(node_id) do
      nil ->
        state

      node when node.node_type in [:decision, :option] ->
        # Look for recent decision nodes on similar topics, scoped to this team
        recent = Graph.recent_decisions(20, team_id: state.team_id)

        conflicts =
          recent
          |> Enum.reject(fn d -> d.id == node_id end)
          |> Enum.filter(fn d ->
            d.agent_name != node.agent_name and
              topics_overlap?(node.title, d.title) and
              different_choices?(node, d)
          end)

        Enum.each(conflicts, fn conflicting ->
          conflict_key = decision_conflict_key(node.id, conflicting.id)

          if not MapSet.member?(state.seen_conflicts, conflict_key) do
            broadcast_conflict(state.team_id, %{
              type: :decision_conflict,
              agent_a: node.agent_name,
              agent_b: conflicting.agent_name,
              description:
                "Contradictory decisions: '#{truncate(node.title, 60)}' vs '#{truncate(conflicting.title, 60)}'"
            })
          end
        end)

        new_seen =
          Enum.reduce(conflicts, state.seen_conflicts, fn c, acc ->
            MapSet.put(acc, decision_conflict_key(node.id, c.id))
          end)

        %{state | seen_conflicts: new_seen}

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp decision_conflict_key(id_a, id_b) do
    [a, b] = Enum.sort([id_a, id_b])
    {:decision, a, b}
  end

  defp topics_overlap?(title_a, title_b) do
    words_a = significant_words(title_a)
    words_b = significant_words(title_b)
    shared = MapSet.intersection(words_a, words_b)
    # At least 2 significant words in common
    MapSet.size(shared) >= 2
  end

  @stop_words ~w(the a an is are was were be been being have has had do does did will would shall should may might can could of to in for on with at by from as into through during before after above below between under)

  defp significant_words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/)
    |> Enum.reject(fn w -> w in @stop_words or String.length(w) < 3 end)
    |> MapSet.new()
  end

  defp different_choices?(node_a, node_b) do
    # If both are decisions with metadata about chosen options, compare them
    choice_a = get_in(node_a.metadata, ["winner"]) || get_in(node_a.metadata, ["chosen"])
    choice_b = get_in(node_b.metadata, ["winner"]) || get_in(node_b.metadata, ["chosen"])

    cond do
      choice_a && choice_b -> choice_a != choice_b
      # If we can't determine choices, assume potential conflict
      true -> true
    end
  end

  # --- Broadcast ---

  defp broadcast_conflict(team_id, %{agent_a: agent_a, agent_b: agent_b, type: type, description: desc} = details) do
    Logger.warning("[ConflictDetector] #{type} in team #{team_id}: #{desc}")

    Comms.broadcast(team_id, {:conflict_detected, details})

    # Inject warnings to both agents
    warning = "[WARNING] Conflict detected (#{type}): #{desc}"

    if agent_a do
      Comms.send_to(team_id, agent_a, {:inject_system_message, warning})
    end

    if agent_b do
      Comms.send_to(team_id, agent_b, {:inject_system_message, warning})
    end
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: String.slice(text, 0, max) <> "..."
end
