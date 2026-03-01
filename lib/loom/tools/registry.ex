defmodule Loom.Tools.Registry do
  @moduledoc "Registry of all available Loom tools."

  @solo_tools [
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
  ]

  @peer_tools [
    Loom.Tools.ContextRetrieve,
    Loom.Tools.ContextOffload,
    Loom.Tools.PeerAskQuestion,
    Loom.Tools.PeerAnswerQuestion,
    Loom.Tools.PeerForwardQuestion
  ]

  @lead_tools [
    Loom.Tools.TeamSpawn,
    Loom.Tools.TeamAssign,
    Loom.Tools.TeamProgress,
    Loom.Tools.TeamDissolve
  ]

  @team_tools @peer_tools ++ @lead_tools

  @all_tools @solo_tools ++ @team_tools

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

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end
end
