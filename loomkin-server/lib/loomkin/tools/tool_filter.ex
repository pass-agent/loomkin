defmodule Loomkin.Tools.ToolFilter do
  @moduledoc """
  Role-specific tool filtering.

  Categorizes tools and restricts which tools each role can access,
  structurally preventing agents from performing wrong-role work.
  For example, researchers cannot write files, and coders cannot
  spawn sub-agents for investigation.

  The filter is applied at two levels:
  1. **Declaration** — `tools_for_role/1` returns the canonical tool list for a role
  2. **Runtime** — `allowed?/2` validates a tool module against a role at execution time

  Tool categories:
  - `:read` — file reading and search (FileRead, FileSearch, ContentSearch, DirectoryList)
  - `:write` — file mutation (FileWrite, FileEdit)
  - `:exec` — command execution (Shell, Git)
  - `:decision` — decision graph tools (DecisionLog, DecisionQuery, PivotDecision, GenerateWriteup)
  - `:peer` — peer communication and context mesh tools
  - `:lead` — team management tools (TeamSpawn, TeamAssign, etc.)
  - `:coordination` — team observation tools (TeamProgress, TeamComms)
  - `:consensus` — collective decision-making (CollectiveDecision)
  - `:cross_team` — cross-team communication (CrossTeamQuery, ListTeams)
  - `:investigation` — autonomous investigation tools (SubAgent, LspDiagnostics)
  - `:graph_merge` — decision graph merging (MergeGraph)
  """

  # -- Tool category definitions --

  @read_tools [
    Loomkin.Tools.FileRead,
    Loomkin.Tools.FileSearch,
    Loomkin.Tools.ContentSearch,
    Loomkin.Tools.DirectoryList
  ]

  @write_tools [
    Loomkin.Tools.FileWrite,
    Loomkin.Tools.FileEdit
  ]

  @exec_tools [
    Loomkin.Tools.Shell,
    Loomkin.Tools.Git
  ]

  @decision_tools [
    Loomkin.Tools.DecisionLog,
    Loomkin.Tools.DecisionQuery,
    Loomkin.Tools.PivotDecision,
    Loomkin.Tools.GenerateWriteup
  ]

  @peer_tools [
    Loomkin.Tools.PeerMessage,
    Loomkin.Tools.PeerDiscovery,
    Loomkin.Tools.PeerClaimRegion,
    Loomkin.Tools.PeerReview,
    Loomkin.Tools.PeerCreateTask,
    Loomkin.Tools.PeerCompleteTask,
    Loomkin.Tools.PeerAskQuestion,
    Loomkin.Tools.PeerAnswerQuestion,
    Loomkin.Tools.PeerForwardQuestion,
    Loomkin.Tools.PeerChangeRole,
    Loomkin.Tools.ContextRetrieve,
    Loomkin.Tools.SearchKeepers,
    Loomkin.Tools.ContextOffload,
    Loomkin.Tools.IntrospectDecisionHistory,
    Loomkin.Tools.IntrospectFailurePatterns,
    Loomkin.Tools.AskUser,
    Loomkin.Tools.SpawnConversation
  ]

  @lead_tools [
    Loomkin.Tools.TeamSpawn,
    Loomkin.Tools.TeamAssign,
    Loomkin.Tools.TeamSmartAssign,
    Loomkin.Tools.TeamProgress,
    Loomkin.Tools.TeamComms,
    Loomkin.Tools.TeamDissolve
  ]

  @coordination_tools [
    Loomkin.Tools.TeamProgress,
    Loomkin.Tools.TeamComms
  ]

  @consensus_tools [
    Loomkin.Tools.CollectiveDecision
  ]

  @cross_team_tools [
    Loomkin.Tools.CrossTeamQuery,
    Loomkin.Tools.ListTeams
  ]

  @investigation_tools [
    Loomkin.Tools.SubAgent,
    Loomkin.Tools.LspDiagnostics
  ]

  @graph_merge_tools [
    Loomkin.Tools.MergeGraph
  ]

  @backlog_tools [
    Loomkin.Tools.QueryBacklog,
    Loomkin.Tools.CreateBacklogItem,
    Loomkin.Tools.UpdateBacklogItem
  ]

  # -- Tool-to-category mapping (built from the lists above) --

  @tool_categories (for {cat, tools} <- [
                          # Process more specific categories first so they win over general ones.
                          # coordination before lead (TeamProgress/TeamComms are coordination tools)
                          coordination: @coordination_tools,
                          consensus: @consensus_tools,
                          backlog: @backlog_tools,
                          read: @read_tools,
                          write: @write_tools,
                          exec: @exec_tools,
                          decision: @decision_tools,
                          peer: @peer_tools,
                          lead: @lead_tools,
                          cross_team: @cross_team_tools,
                          investigation: @investigation_tools,
                          graph_merge: @graph_merge_tools
                        ],
                        tool <- tools,
                        reduce: %{} do
                      acc -> Map.put_new(acc, tool, cat)
                    end)

  # -- Role-to-allowed-categories mapping --
  # Defines which tool categories each role can access.

  @role_categories %{
    researcher: [:read, :decision, :peer, :cross_team],
    coder: [:read, :write, :exec, :decision, :peer, :cross_team],
    reviewer: [:read, :exec, :decision, :peer, :cross_team],
    tester: [:read, :exec, :decision, :peer, :cross_team],
    lead: [
      :read,
      :write,
      :exec,
      :decision,
      :peer,
      :lead,
      :coordination,
      :cross_team,
      :investigation,
      :graph_merge,
      :consensus,
      :backlog
    ],
    concierge: [
      :read,
      :write,
      :exec,
      :decision,
      :peer,
      :lead,
      :coordination,
      :cross_team,
      :investigation,
      :graph_merge,
      :consensus,
      :backlog
    ]
  }

  # -- Public API --

  @doc """
  Returns the canonical list of tool modules for a built-in role.

  This is the single source of truth for which tools a role can access.
  The result is a flat, deduplicated list of tool modules.

  Returns `{:ok, tools}` or `{:error, :unknown_role}` for unrecognized roles.
  For custom/generated roles, use `filter_tools/2` instead.
  """
  @spec tools_for_role(atom()) :: {:ok, [module()]} | {:error, :unknown_role}
  def tools_for_role(role) when is_atom(role) do
    case Map.fetch(@role_categories, role) do
      {:ok, categories} ->
        tools =
          categories
          |> Enum.flat_map(&tools_in_category/1)
          |> Enum.uniq()

        {:ok, tools}

      :error ->
        {:error, :unknown_role}
    end
  end

  @doc """
  Filters a list of tool modules to only those allowed for the given role.

  Useful for custom/generated roles where the LLM may request tools
  that are inappropriate for the role category. Tools not recognized
  by any category are dropped.
  """
  @spec filter_tools(atom(), [module()]) :: [module()]
  def filter_tools(role, tools) when is_atom(role) and is_list(tools) do
    case Map.fetch(@role_categories, role) do
      {:ok, allowed_categories} ->
        allowed_set = MapSet.new(allowed_categories)

        Enum.filter(tools, fn tool ->
          case Map.fetch(@tool_categories, tool) do
            {:ok, cat} -> MapSet.member?(allowed_set, cat)
            :error -> false
          end
        end)

      # Unknown role — return tools unchanged (don't break custom roles)
      :error ->
        tools
    end
  end

  @doc """
  Checks whether a specific tool module is allowed for a given role.

  Returns `true` if the tool is permitted, `false` otherwise.
  Unknown tools (not in any category) return `false`.
  Unknown roles return `true` (permissive for custom roles).
  """
  @spec allowed?(atom(), module()) :: boolean()
  def allowed?(role, tool_module) when is_atom(role) and is_atom(tool_module) do
    case Map.fetch(@role_categories, role) do
      {:ok, allowed_categories} ->
        case Map.fetch(@tool_categories, tool_module) do
          {:ok, cat} -> cat in allowed_categories
          :error -> false
        end

      # Unknown role — permissive
      :error ->
        true
    end
  end

  @doc """
  Returns the category atom for a tool module, or `nil` if not categorized.
  """
  @spec category(module()) :: atom() | nil
  def category(tool_module) when is_atom(tool_module) do
    Map.get(@tool_categories, tool_module)
  end

  @doc """
  Returns the list of allowed tool categories for a role.
  """
  @spec categories_for_role(atom()) :: [atom()]
  def categories_for_role(role) when is_atom(role) do
    Map.get(@role_categories, role, [])
  end

  @doc """
  Returns all tool modules in a given category.
  """
  @spec tools_in_category(atom()) :: [module()]
  def tools_in_category(category) when is_atom(category) do
    case category do
      :read -> @read_tools
      :write -> @write_tools
      :exec -> @exec_tools
      :decision -> @decision_tools
      :peer -> @peer_tools
      :lead -> @lead_tools
      :coordination -> @coordination_tools
      :consensus -> @consensus_tools
      :cross_team -> @cross_team_tools
      :investigation -> @investigation_tools
      :graph_merge -> @graph_merge_tools
      :backlog -> @backlog_tools
      _ -> []
    end
  end

  @doc """
  Returns a human-readable description of denied tools for a role,
  with teamwork-first guidance on how to get the work done.

  Instead of just listing categories, the message guides the agent
  toward asking a teammate for help or requesting a role change.
  """
  @spec denial_reason(atom(), module()) :: String.t()
  def denial_reason(role, tool_module) do
    tool_cat = category(tool_module) || :unknown

    base = "Your role (#{role}) does not include #{tool_cat} tools."

    suggestion = teamwork_suggestion(role, tool_cat)

    base <> " " <> suggestion
  end

  # Teamwork-first suggestions: guide agents toward collaboration, not workarounds.
  # Always mention the concierge as fallback escalation point.
  defp teamwork_suggestion(_role, tool_cat) do
    case tool_cat do
      :write ->
        "Instead of trying workarounds, use peer_message to tell your lead or concierge " <>
          "what you need written — they'll assign a coder to handle it. " <>
          "If you know a coder teammate, ask them directly. " <>
          "Describe WHAT needs to be changed, WHERE (file path + line numbers), and WHY so the coder has full context."

      :exec ->
        "Use peer_message to ask your lead or concierge to assign a coder or tester to run this. " <>
          "If you know a coder or tester teammate, ask them directly. " <>
          "Describe what command you need executed and what output you're looking for."

      :lead ->
        "Team management tools are reserved for lead/concierge roles. " <>
          "Use peer_message to ask your lead or concierge to handle team operations. " <>
          "Describe what you need coordinated and they'll take care of it."

      :investigation ->
        "Use peer_message to ask the lead or concierge to spawn a researcher for this investigation. " <>
          "Describe what you need explored and what questions need answering."

      :read ->
        "Use peer_message to ask a researcher or coder to read this for you. " <>
          "If you don't know who to ask, message the concierge — they'll route your request. " <>
          "Describe what information you need and from which files."

      _ ->
        "Use peer_message to ask your lead or concierge for help — they'll spawn or assign " <>
          "the right specialist. If you know a teammate with #{tool_cat} capability, ask them directly. " <>
          "Describe exactly what you need done and why."
    end
  end
end
