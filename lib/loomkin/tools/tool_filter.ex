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

  # -- Tool-to-category mapping (built from the lists above) --

  @tool_categories (for {cat, tools} <- [
                          # Process more specific categories first so they win over general ones.
                          # coordination before lead (TeamProgress/TeamComms are coordination tools)
                          coordination: @coordination_tools,
                          consensus: @consensus_tools,
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
      :consensus
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
      :consensus
    ],
    weaver: [:peer, :decision, :coordination, :cross_team, :consensus, :graph_merge]
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
      _ -> []
    end
  end

  @doc """
  Returns a human-readable description of denied tools for a role.

  Useful for error messages when an agent tries to use a tool
  outside their role's scope.
  """
  @spec denial_reason(atom(), module()) :: String.t()
  def denial_reason(role, tool_module) do
    tool_cat = category(tool_module) || :unknown
    allowed = categories_for_role(role)

    "Tool category :#{tool_cat} is not allowed for role :#{role}. " <>
      "Allowed categories: #{inspect(allowed)}"
  end
end
