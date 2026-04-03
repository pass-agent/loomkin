defmodule Loomkin.Teams.AgentState do
  @moduledoc """
  Captures the essential, serializable subset of an Agent GenServer's state
  for checkpoint hibernation. Transient process references (loop_task,
  subscription_ids) are excluded — they are re-established on restore.
  """

  alias Loomkin.Teams.Agent

  @type t :: %__MODULE__{}

  defstruct [
    # Identity
    :team_id,
    :session_id,
    :name,
    :role,
    :role_config,
    # Runtime
    :status,
    :model,
    :project_path,
    :system_prompt_extra,
    # Conversation / work
    tools: [],
    messages: [],
    task: nil,
    context: %{},
    # Metrics
    cost_usd: 0.0,
    tokens_used: 0,
    failure_count: 0,
    # Permissions
    permission_mode: :auto,
    pending_permission: nil,
    # Queues
    pending_updates: [],
    priority_queue: [],
    healing_queue: [],
    # Pause / healing state (critical for mid-execution resume)
    pause_requested: false,
    pause_queued: false,
    paused_state: nil,
    frozen_state: nil,
    # User interaction
    last_asked_at: nil,
    pending_ask_user: nil,
    # Team spawning
    spawned_child_teams: [],
    auto_approve_spawns: false,
    # Timer ref — will be nil on restore; caller re-establishes if needed
    wake_ref: nil,
    # Scope detection
    scope_tier: nil,
    files_touched: MapSet.new(),
    task_cost_usd: 0.0
  ]

  @essential_fields [
    :team_id,
    :session_id,
    :name,
    :role,
    :role_config,
    :status,
    :model,
    :project_path,
    :system_prompt_extra,
    :tools,
    :messages,
    :task,
    :context,
    :cost_usd,
    :tokens_used,
    :failure_count,
    :permission_mode,
    :pending_permission,
    :pending_updates,
    :priority_queue,
    :healing_queue,
    :pause_requested,
    :pause_queued,
    :paused_state,
    :frozen_state,
    :last_asked_at,
    :pending_ask_user,
    :spawned_child_teams,
    :auto_approve_spawns,
    :wake_ref,
    :scope_tier,
    :files_touched,
    :task_cost_usd
  ]

  @doc """
  Extracts the essential (checkpoint-worthy) fields from a full Agent state,
  dropping transient process references like `loop_task` and `subscription_ids`.
  """
  @spec extract_essential_state(Agent.t()) :: t()
  def extract_essential_state(%Agent{} = agent) do
    fields = Map.take(agent, @essential_fields)
    struct!(__MODULE__, Map.to_list(fields))
  end

  @doc """
  Serializes an essential state struct to a binary using `:erlang.term_to_binary/1`.
  The resulting binary is suitable for storage in a `bytea` / `:binary` DB column.
  """
  @spec serialize(%__MODULE__{}) :: binary()
  def serialize(%__MODULE__{} = state) do
    :erlang.term_to_binary(state)
  end

  @doc """
  Deserializes a binary back into an `%AgentState{}`.

  Uses the `:safe` option to prevent atom injection from untrusted binaries —
  only atoms that already exist in the VM are allowed.
  """
  @spec deserialize(binary()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def deserialize(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :invalid_binary}
  end

  @doc """
  Merges essential state back into fresh agent init opts, producing
  keyword opts that can be passed to `Agent.start_link/1` to restore
  the agent with its prior conversation and work state.

  Only identity + config fields go into the opts (team_id, name, role, etc.).
  The caller is responsible for injecting the remaining state fields into the
  GenServer after init via a dedicated restore callback.
  """
  @spec merge_into_init(%__MODULE__{}, keyword()) :: keyword()
  def merge_into_init(%__MODULE__{} = state, init_opts \\ []) do
    restored_opts = [
      team_id: state.team_id,
      session_id: state.session_id,
      name: state.name,
      role: state.role,
      role_config: state.role_config,
      model: state.model,
      project_path: state.project_path,
      permission_mode: state.permission_mode
    ]

    Keyword.merge(restored_opts, init_opts)
  end

  # Fields restored from checkpoint into a fresh Agent state.
  # Excludes identity/config fields (already set by init) and transient fields.
  @restorable_fields [
    :messages,
    :task,
    :context,
    :cost_usd,
    :tokens_used,
    :failure_count,
    :pending_updates,
    :priority_queue,
    :healing_queue,
    :paused_state,
    :frozen_state,
    :last_asked_at,
    :pending_ask_user,
    :spawned_child_teams,
    :auto_approve_spawns,
    :scope_tier,
    :files_touched,
    :task_cost_usd
  ]

  @doc """
  Merges restorable fields from a deserialized essential state into a fresh
  Agent struct (as produced by init). Identity and config fields (team_id,
  name, role, etc.) are left as-is from the fresh init — only conversation,
  work, and queue state are restored.
  """
  @spec restore_into_agent(Agent.t(), t()) :: Agent.t()
  def restore_into_agent(%Agent{} = agent, %__MODULE__{} = essential) do
    restored = Map.take(essential, @restorable_fields)
    Map.merge(agent, restored)
  end

  @doc """
  Returns the list of fields that are preserved in essential state snapshots.
  Useful for introspection and testing.
  """
  @spec essential_fields() :: [atom()]
  def essential_fields, do: @essential_fields
end
