defmodule Loomkin.Permissions.TrustPolicy do
  @moduledoc """
  Session-scoped trust policies stored in ETS.
  Allows per-agent or per-role permission policies that override default behavior.

  Policy resolution priority (first match wins):
    1. Exact agent_name + exact tool_category + exact scope
    2. Exact agent_name + exact tool_category + wildcard scope
    3. Exact agent_name + :all tool_category
    4. Role match + exact tool_category + exact scope
    5. Role match + :all tool_category
    6. Wildcard agent + exact tool_category
    7. Wildcard agent + :all tool_category
  """

  alias Loomkin.Permissions.Manager

  defstruct [
    :agent_name,
    :role,
    :tool_category,
    :action,
    :scope
  ]

  @type t :: %__MODULE__{
          agent_name: String.t(),
          role: atom(),
          tool_category: :read | :write | :execute | :coordination | :all,
          action: :auto_approve | :ask | :deny,
          scope: String.t()
        }

  @valid_presets [:strict, :balanced, :autonomous, :full_trust]

  defp preset_policies(:strict) do
    [
      %__MODULE__{agent_name: "*", role: :any, tool_category: :read, action: :ask, scope: "*"},
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :coordination,
        action: :ask,
        scope: "*"
      },
      %__MODULE__{agent_name: "*", role: :any, tool_category: :write, action: :ask, scope: "*"},
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :execute,
        action: :ask,
        scope: "*"
      }
    ]
  end

  defp preset_policies(:balanced) do
    [
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :read,
        action: :auto_approve,
        scope: "*"
      },
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :coordination,
        action: :auto_approve,
        scope: "*"
      },
      %__MODULE__{agent_name: "*", role: :any, tool_category: :write, action: :ask, scope: "*"},
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :execute,
        action: :ask,
        scope: "*"
      }
    ]
  end

  defp preset_policies(:autonomous) do
    [
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :read,
        action: :auto_approve,
        scope: "*"
      },
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :coordination,
        action: :auto_approve,
        scope: "*"
      },
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      },
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :execute,
        action: :ask,
        scope: "*"
      }
    ]
  end

  defp preset_policies(:full_trust) do
    [
      %__MODULE__{
        agent_name: "*",
        role: :any,
        tool_category: :all,
        action: :auto_approve,
        scope: "*"
      }
    ]
  end

  # --- Public API ---

  @doc """
  Creates an ETS table for the given session to store trust policies.
  """
  @spec init(String.t()) :: :ok
  def init(session_id) do
    name = table_name(session_id)

    if :ets.info(name) == :undefined do
      try do
        :ets.new(name, [:set, :public, :named_table])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Initializes the ETS table and optionally applies a preset.

  Useful for re-applying session state on LiveView remount, since the ETS
  table is owned by (and dies with) the creating process.
  """
  @spec init_with_preset(String.t(), atom() | nil) :: :ok | {:error, :unknown_preset}
  def init_with_preset(session_id, nil) do
    init(session_id)
  end

  def init_with_preset(session_id, preset_name) do
    init(session_id)
    apply_preset(session_id, preset_name)
  end

  @doc """
  Deletes the ETS table for the given session.
  """
  @spec cleanup(String.t()) :: :ok
  def cleanup(session_id) do
    name = table_name(session_id)

    if :ets.info(name) != :undefined do
      try do
        :ets.delete(name)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Inserts or updates a trust policy for the session.
  The key is `{agent_name, role, tool_category, scope}`.
  """
  @spec set_policy(String.t(), t()) :: :ok
  def set_policy(session_id, %__MODULE__{} = policy) do
    key = policy_key(policy)
    :ets.insert(table_name(session_id), {key, policy})
    :ok
  end

  @doc """
  Removes a specific trust policy from the session.
  """
  @spec remove_policy(String.t(), t()) :: :ok
  def remove_policy(session_id, %__MODULE__{} = policy) do
    key = policy_key(policy)
    :ets.delete(table_name(session_id), key)
    :ok
  end

  @doc """
  Clears all policies and applies a named preset globally (agent_name "*").

  Valid presets: :strict, :balanced, :autonomous, :full_trust
  """
  @spec apply_preset(String.t(), atom()) :: :ok | {:error, :unknown_preset}
  def apply_preset(session_id, preset_name) when preset_name in @valid_presets do
    name = table_name(session_id)
    :ets.delete_all_objects(name)

    policies = preset_policies(preset_name)

    Enum.each(policies, fn policy ->
      :ets.insert(name, {policy_key(policy), policy})
    end)

    :ets.insert(name, {:__preset__, preset_name})
    :ok
  end

  def apply_preset(_session_id, _preset_name), do: {:error, :unknown_preset}

  @doc """
  Applies a preset scoped to a single agent. Does not clear existing policies.
  """
  @spec apply_preset_for_agent(String.t(), String.t(), atom()) :: :ok | {:error, :unknown_preset}
  def apply_preset_for_agent(session_id, agent_name, preset_name)
      when preset_name in @valid_presets do
    name = table_name(session_id)
    policies = preset_policies(preset_name)

    Enum.each(policies, fn policy ->
      scoped = %{policy | agent_name: agent_name}
      :ets.insert(name, {policy_key(scoped), scoped})
    end)

    :ok
  end

  def apply_preset_for_agent(_session_id, _agent_name, _preset_name),
    do: {:error, :unknown_preset}

  @doc """
  Checks trust policies for a given agent + tool invocation.

  Returns `:auto_approve`, `:ask`, `:deny`, or `nil` (no matching policy).
  """
  @spec check(String.t(), String.t(), atom(), String.t(), String.t()) ::
          :auto_approve | :ask | :deny | nil
  def check(session_id, agent_name, role, tool_name, tool_path) do
    name = table_name(session_id)

    if :ets.info(name) == :undefined do
      nil
    else
      category = Manager.tool_category(tool_name)
      resolve(name, agent_name, role, category, tool_path)
    end
  end

  @doc """
  Returns all trust policies for the session (excluding internal metadata).
  """
  @spec list_policies(String.t()) :: [t()]
  def list_policies(session_id) do
    name = table_name(session_id)

    if :ets.info(name) == :undefined do
      []
    else
      name
      |> :ets.tab2list()
      |> Enum.reject(fn {key, _val} -> key == :__preset__ end)
      |> Enum.map(fn {_key, policy} -> policy end)
    end
  end

  @doc """
  Returns the current global preset name if one is active, nil otherwise.
  """
  @spec get_preset_name(String.t()) :: atom() | nil
  def get_preset_name(session_id) do
    name = table_name(session_id)

    if :ets.info(name) == :undefined do
      nil
    else
      case :ets.lookup(name, :__preset__) do
        [{:__preset__, preset_name}] -> preset_name
        [] -> nil
      end
    end
  end

  @doc """
  Returns the list of valid preset names.
  """
  @spec preset_names :: [atom()]
  def preset_names, do: @valid_presets

  # --- Private ---

  defp table_name(session_id), do: :"trust_policies_#{session_id}"

  defp policy_key(%__MODULE__{} = p) do
    {p.agent_name, p.role, p.tool_category, p.scope}
  end

  # Policy resolution: check candidates in priority order, return first match.
  defp resolve(table, agent_name, role, category, path) do
    candidates = [
      # 1. Exact agent + exact category + exact scope
      {agent_name, :any, category, path},
      # 2. Exact agent + exact category + wildcard scope
      {agent_name, :any, category, "*"},
      # 3. Exact agent + :all category
      {agent_name, :any, :all, "*"},
      # 4. Role match + exact category + exact scope
      {agent_name, role, category, path},
      {"*", role, category, path},
      # 4b. Role match + exact category + wildcard scope
      {agent_name, role, category, "*"},
      {"*", role, category, "*"},
      # 5. Role match + :all category
      {agent_name, role, :all, "*"},
      {"*", role, :all, "*"},
      # 6. Wildcard agent + exact category
      {"*", :any, category, path},
      {"*", :any, category, "*"},
      # 7. Wildcard agent + :all category
      {"*", :any, :all, "*"}
    ]

    Enum.find_value(candidates, fn key ->
      case :ets.lookup(table, key) do
        [{_key, %__MODULE__{action: action}}] -> action
        [] -> nil
      end
    end)
  end
end
