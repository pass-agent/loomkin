defmodule Loomkin.Tools.Registry do
  @moduledoc "Registry of all available Loomkin tools."

  @solo_tools [
    Loomkin.Tools.FileRead,
    Loomkin.Tools.FileWrite,
    Loomkin.Tools.FileEdit,
    Loomkin.Tools.FileSearch,
    Loomkin.Tools.ContentSearch,
    Loomkin.Tools.DirectoryList,
    Loomkin.Tools.Shell,
    Loomkin.Tools.Git,
    Loomkin.Tools.DecisionLog,
    Loomkin.Tools.DecisionQuery,
    Loomkin.Tools.SubAgent,
    Loomkin.Tools.LspDiagnostics,
    Loomkin.Tools.LoadSkill
  ]

  @peer_tools [
    Loomkin.Tools.ContextRetrieve,
    Loomkin.Tools.SearchKeepers,
    Loomkin.Tools.ContextOffload,
    Loomkin.Tools.PeerAskQuestion,
    Loomkin.Tools.PeerAnswerQuestion,
    Loomkin.Tools.PeerForwardQuestion,
    Loomkin.Tools.CollectiveDecision,
    Loomkin.Tools.AskUser,
    Loomkin.Tools.RequestApproval,
    Loomkin.Tools.PeerEmitMilestone,
    Loomkin.Tools.PeerAddDependency,
    Loomkin.Tools.PeerUpdateTaskStatus,
    Loomkin.Tools.PeerSignalReady,
    Loomkin.Tools.PeerResumeTask,
    Loomkin.Tools.PeerStartSpeculative,
    Loomkin.Tools.PeerConfirmTentative,
    Loomkin.Tools.PeerDiscardTentative,
    Loomkin.Tools.PeerNegotiateTask,
    Loomkin.Tools.SpawnConversation,
    Loomkin.Tools.IntrospectDecisionHistory,
    Loomkin.Tools.IntrospectFailurePatterns
  ]

  @lead_tools [
    Loomkin.Tools.TeamSpawn,
    Loomkin.Tools.TeamAssign,
    Loomkin.Tools.TeamProgress,
    Loomkin.Tools.TeamComms,
    Loomkin.Tools.TeamDissolve,
    Loomkin.Tools.CreateRendezvous,
    Loomkin.Tools.PeerResolveNegotiation
  ]

  @healing_tools [
    Loomkin.Tools.DiagnosisReport,
    Loomkin.Tools.FixConfirmation,
    Loomkin.Tools.VerifyLoop,
    Loomkin.Tools.AcceptanceChecks
  ]

  @team_tools @peer_tools ++ @lead_tools

  @all_tools @solo_tools ++ @team_tools ++ @healing_tools

  @doc "Returns solo-safe tool modules (no team context required)."
  @spec all() :: [module()]
  def all, do: @solo_tools

  @doc "Returns all registered tool modules including team-only tools."
  @spec all_with_team() :: [module()]
  def all_with_team, do: @all_tools

  @doc "Returns team-only tool modules (peer + lead tools)."
  @spec team_tools() :: [module()]
  def team_tools, do: @team_tools

  @doc "Returns lead-only tools (team_spawn, team_assign, team_progress, team_dissolve)."
  @spec lead_tools() :: [module()]
  def lead_tools, do: @lead_tools

  @doc "Returns healing-specific tools (diagnosis_report, fix_confirmation)."
  @spec healing_tools() :: [module()]
  def healing_tools, do: @healing_tools

  @doc "Returns the full tool set for a lead agent (solo + all team tools)."
  @spec for_lead() :: [module()]
  def for_lead, do: @all_tools

  @doc "Returns the tool definitions for all registered tools as ReqLLM.Tool structs."
  @spec definitions() :: [ReqLLM.Tool.t()]
  def definitions do
    Jido.AI.ToolAdapter.from_actions(@all_tools)
  end

  @doc "Returns tool definitions for a specific list of tool modules."
  @spec definitions_for([module()]) :: [ReqLLM.Tool.t()]
  def definitions_for(tool_modules) when is_list(tool_modules) do
    Jido.AI.ToolAdapter.from_actions(tool_modules)
  end

  @doc "Finds a tool module by its string name (e.g. \"file_read\")."
  @spec find(String.t()) :: {:ok, module()} | {:error, String.t()}
  def find(name) when is_binary(name) do
    case Jido.AI.ToolAdapter.lookup_action(name, @all_tools) do
      {:ok, module} -> {:ok, module}
      {:error, :not_found} -> {:error, "Unknown tool: #{name}"}
    end
  end

  @doc "Looks up a tool by name and runs it with the given params and context via Jido.Exec."
  @spec execute(String.t(), map(), map(), keyword()) :: {:ok, any()} | {:error, any()}
  def execute(tool_name, params, context, opts \\ []) do
    case find(tool_name) do
      {:ok, mod} ->
        # Jido.Exec validates params via NimbleOptions (atom keys).
        # LLM tool calls arrive with string keys, so normalize here.
        normalized = atomize_keys(params)
        Jido.Exec.run(mod, normalized, context, Keyword.put_new(opts, :timeout, 60_000))

      error ->
        error
    end
  end

  # All known tool parameter keys collected from tool schemas.
  # Only these keys are converted from string to atom. Unknown keys
  # from LLM output are kept as strings to prevent atom table exhaustion.
  @known_param_keys ~w(
    command timeout file_path content old_string new_string replace_all
    pattern path glob offset limit operation args
    node_type title description confidence parent_id edge_type metadata
    query_type search_term
    team_name roles project_path team_id agent_name priority
    question target context query keeper_id mode topic message_count
    query_id answer enrichment to new_role require_approval
    start_line end_line diff task scope severity task_id result name role count
    options
    gate_id gate_context
    depends_on_id dep_type milestone_name
    new_status reason ready_for rendezvous_id required_agents on_complete_message timeout_minutes
    response counter_proposal resolution
    blocker_task_id assumed_output requeue
    session_id root_cause affected_files suggested_fix files_changed verified
    verification_output
    personas max_rounds facilitator template
    check_type spec_description
    test_command success_criteria max_iterations
    minutes
  )a

  @known_param_key_map Map.new(@known_param_keys, fn atom -> {Atom.to_string(atom), atom} end)

  @doc false
  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  def atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  def atomize_keys(value), do: value

  # Convert known tool parameter keys to atoms. Unknown keys stay as strings.
  defp safe_to_atom(s) when is_binary(s) do
    case Map.fetch(@known_param_key_map, s) do
      {:ok, atom} -> atom
      :error -> s
    end
  end
end
