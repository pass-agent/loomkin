defmodule Loom.Teams.Role do
  @moduledoc """
  Defines per-role configuration for team agents: tools, system prompt, limits.

  All roles use the same user-configured model (uniform model default). Agents
  differ in their tools and system prompts, not their intelligence level. The
  `model_tier` field is kept for backward compatibility but defaults to `:default`
  for all built-in roles — meaning "use whatever the user configured."
  """

  defstruct [:name, :model_tier, :tools, :max_iterations, :system_prompt, :budget_limit]

  @type t :: %__MODULE__{
          name: atom(),
          model_tier: atom(),
          tools: [module()],
          max_iterations: pos_integer(),
          system_prompt: String.t(),
          budget_limit: float() | nil
        }

  # Legacy tier map — kept only for backward-compatible `model_for_tier/1` calls
  # and legacy config parsing. New code should use `ModelRouter.default_model/0`.
  @legacy_tier_models %{
    grunt: "zai:glm-4.5",
    standard: "zai:glm-5",
    expert: "anthropic:claude-sonnet-4-6",
    architect: "anthropic:claude-opus-4-6"
  }

  # -- Tool groups --

  @read_only_tools [
    Loom.Tools.FileRead,
    Loom.Tools.FileSearch,
    Loom.Tools.ContentSearch,
    Loom.Tools.DirectoryList
  ]

  @decision_tools [
    Loom.Tools.DecisionLog,
    Loom.Tools.DecisionQuery
  ]

  @write_tools [
    Loom.Tools.FileWrite,
    Loom.Tools.FileEdit
  ]

  @exec_tools [
    Loom.Tools.Shell,
    Loom.Tools.Git
  ]

  @peer_tools [
    Loom.Tools.PeerMessage,
    Loom.Tools.PeerDiscovery,
    Loom.Tools.PeerClaimRegion,
    Loom.Tools.PeerReview,
    Loom.Tools.PeerCreateTask,
    Loom.Tools.PeerAskQuestion,
    Loom.Tools.PeerAnswerQuestion,
    Loom.Tools.PeerForwardQuestion,
    Loom.Tools.ContextRetrieve,
    Loom.Tools.ContextOffload
  ]

  @lead_tools [
    Loom.Tools.TeamSpawn,
    Loom.Tools.TeamAssign,
    Loom.Tools.TeamProgress,
    Loom.Tools.TeamDissolve
  ]

  @all_tools [
    Loom.Tools.FileRead,
    Loom.Tools.FileWrite,
    Loom.Tools.FileEdit,
    Loom.Tools.FileSearch,
    Loom.Tools.ContentSearch,
    Loom.Tools.DirectoryList,
    Loom.Tools.Shell,
    Loom.Tools.Git,
    Loom.Tools.DecisionLog,
    Loom.Tools.DecisionQuery,
    Loom.Tools.SubAgent,
    Loom.Tools.LspDiagnostics
  ] ++ @lead_tools ++ @peer_tools

  @tool_name_to_module %{
    "file_read" => Loom.Tools.FileRead,
    "file_write" => Loom.Tools.FileWrite,
    "file_edit" => Loom.Tools.FileEdit,
    "file_search" => Loom.Tools.FileSearch,
    "content_search" => Loom.Tools.ContentSearch,
    "directory_list" => Loom.Tools.DirectoryList,
    "shell" => Loom.Tools.Shell,
    "git" => Loom.Tools.Git,
    "decision_log" => Loom.Tools.DecisionLog,
    "decision_query" => Loom.Tools.DecisionQuery,
    "sub_agent" => Loom.Tools.SubAgent,
    "lsp_diagnostics" => Loom.Tools.LspDiagnostics,
    "team_spawn" => Loom.Tools.TeamSpawn,
    "team_assign" => Loom.Tools.TeamAssign,
    "team_progress" => Loom.Tools.TeamProgress,
    "team_dissolve" => Loom.Tools.TeamDissolve,
    "peer_message" => Loom.Tools.PeerMessage,
    "peer_discovery" => Loom.Tools.PeerDiscovery,
    "peer_claim_region" => Loom.Tools.PeerClaimRegion,
    "peer_review" => Loom.Tools.PeerReview,
    "peer_create_task" => Loom.Tools.PeerCreateTask,
    "peer_ask_question" => Loom.Tools.PeerAskQuestion,
    "peer_answer_question" => Loom.Tools.PeerAnswerQuestion,
    "peer_forward_question" => Loom.Tools.PeerForwardQuestion,
    "context_retrieve" => Loom.Tools.ContextRetrieve,
    "context_offload" => Loom.Tools.ContextOffload
  }

  # -- Context Mesh prompt blocks --

  @context_mesh_prompt """

  ## Context Mesh

  You have access to a shared knowledge system called the Context Mesh. It allows you to:
  - **Offload** completed work to persistent Keepers (use `context_offload` tool)
  - **Retrieve** knowledge from any Keeper (use `context_retrieve` tool)
  - **Discover** what teammates know (use `peer_discovery` tool)

  ### When to Offload
  - After completing a subtask or research topic
  - Before switching to a new topic
  - When you see a context pressure warning (>50%)

  ### When to Retrieve
  - Before starting work on a new task — check if someone already explored this
  - When answering questions — keepers may have relevant context
  - When you see a keeper notification from a teammate

  ### Available Keepers
  {keeper_index}
  """

  @context_role_guidance %{
    lead:
      "Before decomposing tasks, check keepers for prior analysis. Offload synthesis and decisions after planning.",
    researcher:
      "Offload findings after each subtask. Always check keepers before starting new research — avoid duplicate work. Broadcast important discoveries.",
    coder:
      "Retrieve design context and research from keepers before implementing. Offload implementation notes and decisions for reviewers.",
    reviewer:
      "Query keepers for design context, requirements, and implementation notes before reviewing code.",
    tester:
      "Query keepers for implementation notes and design decisions to inform your test strategy."
  }

  # -- Built-in role definitions --
  #
  # All roles use `model_tier: :default` — the uniform model default.
  # Agents are differentiated by tools and system prompts, not model intelligence.

  @built_in_role_data %{
    lead: %{
      model_tier: :default,
      tools: @all_tools,
      max_iterations: 25,
      system_prompt: """
      You are the team lead. Your job is to decompose complex tasks into smaller subtasks,
      coordinate work across team agents, and synthesize results into a coherent response.

      Priorities:
      - Break down the user's request into clear, actionable subtasks before delegating
      - Assign subtasks to the most appropriate role (researcher, coder, reviewer, tester)
      - Monitor progress and resolve blockers
      - Synthesize findings and results from team agents into a final answer
      - Log key decisions and rationale using the decision tools
      - Only write code yourself for trivial glue or when no coder is available
      """
    },
    researcher: %{
      model_tier: :default,
      tools: @read_only_tools ++ @decision_tools ++ @peer_tools,
      max_iterations: 15,
      system_prompt: """
      You are a research agent. Your job is to explore the codebase, analyze patterns,
      and report findings to the team lead.

      Priorities:
      - Read and understand code thoroughly before reporting
      - Search broadly first, then drill into specifics
      - Identify relevant files, modules, functions, and dependencies
      - Summarize findings clearly with file paths and line references
      - Note patterns, conventions, and potential issues
      - Log important discoveries using the decision tools
      - Never modify files — you are read-only
      """
    },
    coder: %{
      model_tier: :default,
      tools: @read_only_tools ++ @write_tools ++ @exec_tools ++ [Loom.Tools.DecisionLog] ++ @peer_tools,
      max_iterations: 25,
      system_prompt: """
      You are a coding agent. Your job is to implement changes, write code, and run commands.

      Priorities:
      - Read existing code before making changes to understand context and conventions
      - Make minimal, focused edits — avoid unnecessary rewrites
      - Follow the project's existing code style and patterns
      - Run the compiler and tests after making changes to verify correctness
      - Use git to stage and commit completed work when instructed
      - Log significant implementation decisions
      - If a task is unclear, ask the lead for clarification rather than guessing
      """
    },
    reviewer: %{
      model_tier: :default,
      tools: @read_only_tools ++ [Loom.Tools.Shell] ++ @decision_tools ++ @peer_tools,
      max_iterations: 10,
      system_prompt: """
      You are a code review agent. Your job is to review code quality, find issues,
      and suggest improvements.

      Priorities:
      - Check for correctness, security vulnerabilities, and edge cases
      - Verify the code follows project conventions and patterns
      - Look for missing error handling and potential failure modes
      - Run the compiler and any linters to catch issues
      - Provide specific, actionable feedback with file paths and line numbers
      - Distinguish between blocking issues and optional improvements
      - Log review findings using the decision tools
      """
    },
    tester: %{
      model_tier: :default,
      tools: @read_only_tools ++ [Loom.Tools.Shell, Loom.Tools.DecisionLog] ++ @peer_tools,
      max_iterations: 15,
      system_prompt: """
      You are a testing agent. Your job is to run tests, validate changes, and report results.

      Priorities:
      - Run the relevant test suite to check for regressions
      - Verify that new code has adequate test coverage
      - Report test results clearly — passing count, failures with details
      - If tests fail, analyze the failure output and identify root causes
      - Suggest missing test cases for edge cases and error paths
      - Log test results and coverage observations
      - Use shell commands to run mix test and other validation tools
      """
    }
  }

  @doc "Get role configuration by name."
  @spec get(atom()) :: {:ok, t()} | {:error, :unknown_role}
  def get(name) when is_atom(name) do
    case Map.fetch(@built_in_role_data, name) do
      {:ok, data} ->
        data = Map.update!(data, :system_prompt, &append_context_awareness(name, &1))
        {:ok, struct!(__MODULE__, Map.put(data, :name, name))}

      :error ->
        {:error, :unknown_role}
    end
  end

  defp append_context_awareness(role, base_prompt) do
    role_guidance = Map.get(@context_role_guidance, role, "")

    base_prompt <>
      "\n### Context Awareness\n" <>
      role_guidance <>
      @context_mesh_prompt
  end

  @doc """
  Get the model string for a tier (legacy).

  For the `:default` tier, delegates to `Loom.Teams.ModelRouter.default_model/0`.
  For legacy tier atoms (`:grunt`, `:standard`, `:expert`, `:architect`), returns
  the hardcoded model string for backward compatibility.

  New code should use `Loom.Teams.ModelRouter.default_model/0` directly.
  """
  @spec model_for_tier(atom()) :: String.t()
  def model_for_tier(:default) do
    Loom.Teams.ModelRouter.default_model()
  end

  def model_for_tier(tier) when is_atom(tier) do
    Map.get(@legacy_tier_models, tier, Loom.Teams.ModelRouter.default_model())
  end

  @doc "List all built-in role names."
  @spec built_in_roles() :: [atom()]
  def built_in_roles do
    Map.keys(@built_in_role_data)
  end

  @doc "Load a custom role from a config map (e.g. from .loom.toml [teams.roles.*])."
  @spec from_config(atom(), map()) :: t()
  def from_config(name, config) when is_atom(name) and is_map(config) do
    base =
      case Map.fetch(@built_in_role_data, name) do
        {:ok, data} -> struct!(__MODULE__, Map.put(data, :name, name))
        :error -> %__MODULE__{name: name}
      end

    %__MODULE__{
      name: name,
      model_tier: get_config_value(config, :model_tier, base.model_tier),
      tools: resolve_tools(config, base.tools),
      max_iterations: get_config_value(config, :max_iterations, base.max_iterations),
      system_prompt: get_config_value(config, :system_prompt, base.system_prompt),
      budget_limit: get_config_value(config, :budget_limit, base.budget_limit)
    }
  end

  # -- Helpers --

  defp get_config_value(config, key, default) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp resolve_tools(config, default) do
    case Map.get(config, :tools, Map.get(config, "tools")) do
      nil ->
        default

      tool_names when is_list(tool_names) ->
        Enum.map(tool_names, fn
          name when is_binary(name) -> Map.get(@tool_name_to_module, name, name)
          mod when is_atom(mod) -> mod
        end)
    end
  end
end
