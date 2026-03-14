defmodule Loomkin.Settings.Registry do
  @moduledoc """
  Central catalog of all configurable settings.

  Each setting is a `%Setting{}` struct carrying label, description, type info,
  defaults, and validation constraints. The settings LiveView renders entirely
  from this data — no hardcoded form fields in templates.
  """

  alias Loomkin.Settings.Setting

  @settings [
    # ── Agents: Team Structure ────────────────────────────────────────
    %Setting{
      key: [:teams, :orchestrator_mode],
      label: "Orchestrator mode",
      description:
        "When enabled, the lead agent orchestrates work across the team instead of doing tasks directly.",
      why_change:
        "Disable for small, single-agent sessions where orchestration overhead isn't needed.",
      type: :toggle,
      default: true,
      tab: "Agents",
      section: "Team Structure",
      applies_to_new: true
    },
    %Setting{
      key: [:teams, :max_nesting_depth],
      label: "Max sub-team nesting depth",
      description:
        "How many levels deep sub-teams can be spawned. A depth of 2 means teams can have sub-teams, which can have their own sub-teams.",
      why_change:
        "Increase for complex projects that need deep specialization hierarchies. Decrease to keep team structures flat and simple.",
      type: :number,
      default: 2,
      range: {1, 5},
      step: 1,
      tab: "Agents",
      section: "Team Structure",
      applies_to_new: true
    },

    # ── Agents: Consensus & Debate ────────────────────────────────────
    %Setting{
      key: [:teams, :consensus, :quorum],
      label: "Consensus quorum",
      description: "How many agents must agree for a team decision to pass.",
      why_change:
        "Use 'unanimous' for high-stakes decisions where every agent must agree. Use 'majority' for faster throughput.",
      type: :select,
      options: ["majority", "unanimous"],
      default: "majority",
      tab: "Agents",
      section: "Consensus & Debate"
    },
    %Setting{
      key: [:teams, :consensus, :max_rounds],
      label: "Max consensus rounds",
      description: "Maximum debate rounds before a decision is forced or escalated.",
      why_change:
        "Increase if agents need more time to converge on complex decisions. Decrease for faster resolution.",
      type: :number,
      default: 3,
      range: {1, 10},
      step: 1,
      tab: "Agents",
      section: "Consensus & Debate"
    },
    %Setting{
      key: [:teams, :consensus, :on_deadlock],
      label: "Deadlock resolution",
      description: "What happens when agents can't reach consensus after max rounds.",
      why_change:
        "Use 'escalate_to_user' when human oversight is critical. Use 'leader_decides' for autonomous operation.",
      type: :select,
      options: ["escalate_to_user", "leader_decides"],
      default: "escalate_to_user",
      tab: "Agents",
      section: "Consensus & Debate"
    },
    %Setting{
      key: [:teams, :debate, :max_rounds],
      label: "Max debate rounds",
      description:
        "Maximum rounds of structured debate between agents before convergence is forced.",
      why_change:
        "Increase for nuanced architectural debates. Decrease for simple disagreements that don't warrant extended discussion.",
      type: :number,
      default: 3,
      range: {1, 10},
      step: 1,
      tab: "Agents",
      section: "Consensus & Debate"
    },
    %Setting{
      key: [:teams, :debate, :round_timeout_ms],
      label: "Debate round timeout",
      description: "Maximum time allowed for each debate round phase before it's auto-closed.",
      why_change:
        "Increase if debates involve complex LLM reasoning that needs more time. Decrease if agents are stalling.",
      type: :duration,
      default: 30_000,
      range: {5_000, 300_000},
      step: 1_000,
      unit: "ms",
      tab: "Agents",
      section: "Consensus & Debate"
    },

    # ── Agents: Execution Limits ──────────────────────────────────────
    %Setting{
      key: [:agents, :max_iterations],
      label: "Max loop iterations",
      description:
        "Maximum think-act-observe cycles an agent can perform per task. Each iteration is one LLM call plus tool executions.",
      why_change:
        "Increase for complex multi-step refactors. Decrease for cost control on simple tasks.",
      type: :number,
      default: 25,
      range: {1, 100},
      step: 1,
      tab: "Agents",
      section: "Execution Limits"
    },
    %Setting{
      key: [:agents, :max_rate_limit_retries],
      label: "Rate limit retries",
      description:
        "How many times an agent retries after hitting a provider rate limit before giving up.",
      why_change:
        "Increase if you're on a high-volume plan and rate limits are transient. Decrease to fail fast.",
      type: :number,
      default: 3,
      range: {0, 10},
      step: 1,
      tab: "Agents",
      section: "Execution Limits"
    },
    %Setting{
      key: [:agents, :llm_max_retries],
      label: "LLM error retries",
      description:
        "Maximum retry attempts for transient LLM errors (timeouts, 500s) before the request fails.",
      why_change:
        "Increase if your provider has intermittent issues. Decrease to surface errors faster.",
      type: :number,
      default: 3,
      range: {0, 10},
      step: 1,
      tab: "Agents",
      section: "Execution Limits"
    },
    %Setting{
      key: [:agents, :llm_base_backoff_ms],
      label: "LLM retry backoff base",
      description:
        "Base delay for exponential backoff between LLM retries. Actual delay is base * 2^attempt.",
      why_change:
        "Increase if provider rate limits need longer cool-down. Decrease for faster retry cycles.",
      type: :duration,
      default: 1_000,
      range: {100, 30_000},
      step: 100,
      unit: "ms",
      tab: "Agents",
      section: "Execution Limits"
    },
    %Setting{
      key: [:agents, :shell_timeout_ms],
      label: "Shell command timeout",
      description: "Maximum time a shell command can run before being killed.",
      why_change:
        "Increase for long-running builds or test suites. Decrease if agents are hanging on stuck commands.",
      type: :duration,
      default: 30_000,
      range: {1_000, 600_000},
      step: 1_000,
      unit: "ms",
      tab: "Agents",
      section: "Execution Limits"
    },
    %Setting{
      key: [:agents, :shell_max_output_chars],
      label: "Shell output limit",
      description:
        "Maximum characters of shell output kept before truncation. Longer output is trimmed from the middle.",
      why_change:
        "Increase for verbose test output you need to see in full. Decrease to save context window tokens.",
      type: :number,
      default: 10_000,
      range: {1_000, 100_000},
      step: 1_000,
      unit: "chars",
      tab: "Agents",
      section: "Execution Limits"
    },

    # ── Budgets: Team & Agent Budgets ─────────────────────────────────
    %Setting{
      key: [:teams, :budget, :max_per_team_usd],
      label: "Team budget",
      description: "Maximum USD spend per team before further LLM calls are blocked.",
      why_change:
        "Increase for large projects where teams need more runway. Decrease for tighter cost control.",
      type: :currency,
      default: 5.00,
      range: {0.10, 100.00},
      step: 0.10,
      tab: "Budgets",
      section: "Team & Agent Budgets",
      applies_to_new: true
    },
    %Setting{
      key: [:teams, :budget, :max_per_agent_usd],
      label: "Agent budget",
      description: "Maximum USD spend per individual agent before it stops making LLM calls.",
      why_change:
        "Increase for agents working on complex tasks. Decrease to catch runaway agents early.",
      type: :currency,
      default: 1.00,
      range: {0.05, 50.00},
      step: 0.05,
      tab: "Budgets",
      section: "Team & Agent Budgets",
      applies_to_new: true
    },

    # ── Budgets: Provider Rate Limits ─────────────────────────────────
    %Setting{
      key: [:teams, :budget, :provider_limits, :anthropic_tokens_per_min],
      label: "Anthropic token limit",
      description: "Maximum tokens per minute across all agents using Anthropic models.",
      why_change: "Match to your Anthropic API plan's rate limit to avoid 429 errors.",
      type: :number,
      default: 80_000,
      range: {1_000, 1_000_000},
      step: 1_000,
      unit: "tokens/min",
      tab: "Budgets",
      section: "Provider Rate Limits"
    },
    %Setting{
      key: [:teams, :budget, :provider_limits, :openai_tokens_per_min],
      label: "OpenAI token limit",
      description: "Maximum tokens per minute across all agents using OpenAI models.",
      why_change: "Match to your OpenAI API plan's rate limit.",
      type: :number,
      default: 90_000,
      range: {1_000, 1_000_000},
      step: 1_000,
      unit: "tokens/min",
      tab: "Budgets",
      section: "Provider Rate Limits"
    },
    %Setting{
      key: [:teams, :budget, :provider_limits, :google_tokens_per_min],
      label: "Google token limit",
      description: "Maximum tokens per minute across all agents using Google models.",
      why_change: "Match to your Google AI API plan's rate limit.",
      type: :number,
      default: 60_000,
      range: {1_000, 1_000_000},
      step: 1_000,
      unit: "tokens/min",
      tab: "Budgets",
      section: "Provider Rate Limits"
    },

    # ── Budgets: Retry & Resilience ───────────────────────────────────
    %Setting{
      key: [:agents, :complexity_check_interval_ms],
      label: "Complexity check interval",
      description:
        "How often the complexity monitor evaluates agent workload to suggest spawning helpers.",
      why_change:
        "Decrease for faster detection of overloaded agents. Increase to reduce monitoring overhead.",
      type: :duration,
      default: 60_000,
      range: {10_000, 600_000},
      step: 5_000,
      unit: "ms",
      tab: "Budgets",
      section: "Retry & Resilience"
    },
    %Setting{
      key: [:agents, :complexity_threshold],
      label: "Complexity threshold",
      description: "Score (0-100) above which the monitor suggests spawning additional agents.",
      why_change:
        "Lower to spawn helpers earlier for complex tasks. Raise if too many unnecessary agents are being suggested.",
      type: :number,
      default: 60,
      range: {10, 100},
      step: 5,
      tab: "Budgets",
      section: "Retry & Resilience"
    },
    %Setting{
      key: [:agents, :spawn_cooldown_ms],
      label: "Spawn cooldown",
      description:
        "Minimum time between complexity-triggered spawn suggestions for the same team.",
      why_change:
        "Increase if the monitor is too aggressive with spawn suggestions. Decrease for faster scaling.",
      type: :duration,
      default: 300_000,
      range: {30_000, 1_800_000},
      step: 30_000,
      unit: "ms",
      tab: "Budgets",
      section: "Retry & Resilience"
    },

    # ── Healing: Global Controls ──────────────────────────────────────
    %Setting{
      key: [:healing, :budget_usd],
      label: "Healing budget",
      description:
        "Maximum USD the healing orchestrator can spend per healing session trying to fix a failure.",
      why_change:
        "Increase for complex failures that need multiple LLM-guided repair attempts. Decrease for cost control.",
      type: :currency,
      default: 0.50,
      range: {0.05, 10.00},
      step: 0.05,
      tab: "Healing",
      section: "Global Healing Controls"
    },
    %Setting{
      key: [:healing, :max_iterations],
      label: "Max healing iterations",
      description: "Maximum think-act-observe cycles the healing agent can perform per failure.",
      why_change:
        "Increase for stubborn failures that need iterative debugging. Decrease to fail fast and escalate.",
      type: :number,
      default: 15,
      range: {1, 50},
      step: 1,
      tab: "Healing",
      section: "Global Healing Controls"
    },
    %Setting{
      key: [:healing, :max_attempts],
      label: "Max healing attempts",
      description:
        "How many times the orchestrator retries healing before escalating the failure.",
      why_change:
        "Increase if initial healing attempts often partially fix issues. Decrease to escalate sooner.",
      type: :number,
      default: 2,
      range: {1, 5},
      step: 1,
      tab: "Healing",
      section: "Global Healing Controls"
    },
    %Setting{
      key: [:healing, :timeout_ms],
      label: "Healing session timeout",
      description: "Maximum total time for an entire healing session before it's abandoned.",
      why_change:
        "Increase for complex failures in large codebases. Decrease to free up resources faster.",
      type: :duration,
      default: 300_000,
      range: {30_000, 1_800_000},
      step: 30_000,
      unit: "ms",
      tab: "Healing",
      section: "Global Healing Controls"
    },

    # ── Healing: Rebalancer ───────────────────────────────────────────
    %Setting{
      key: [:healing, :rebalancer_check_interval_ms],
      label: "Rebalancer check interval",
      description: "How often the rebalancer checks for stuck or idle agents.",
      why_change:
        "Decrease for faster detection of stuck agents. Increase to reduce monitoring overhead.",
      type: :duration,
      default: 60_000,
      range: {10_000, 600_000},
      step: 5_000,
      unit: "ms",
      tab: "Healing",
      section: "Rebalancer"
    },
    %Setting{
      key: [:healing, :stuck_threshold_ms],
      label: "Stuck agent threshold",
      description: "How long an agent can be idle before the rebalancer considers it stuck.",
      why_change:
        "Increase if agents legitimately wait for external resources. Decrease for tighter health monitoring.",
      type: :duration,
      default: 300_000,
      range: {30_000, 1_800_000},
      step: 30_000,
      unit: "ms",
      tab: "Healing",
      section: "Rebalancer"
    },
    %Setting{
      key: [:healing, :max_nudges],
      label: "Max rebalancer nudges",
      description: "How many times the rebalancer nudges a stuck agent before escalating.",
      why_change:
        "Increase if agents often recover after a nudge. Decrease to escalate stuck agents faster.",
      type: :number,
      default: 2,
      range: {1, 10},
      step: 1,
      tab: "Healing",
      section: "Rebalancer"
    },

    # ── Intelligence: Context Window ──────────────────────────────────
    %Setting{
      key: [:context, :max_repo_map_tokens],
      label: "Repo map token budget",
      description: "Maximum tokens allocated for the repository structure map in agent context.",
      why_change:
        "Increase for large monorepos where agents need more structural awareness. Decrease to free tokens for conversation.",
      type: :number,
      default: 2048,
      range: {256, 8192},
      step: 256,
      unit: "tokens",
      tab: "Intelligence",
      section: "Context Window"
    },
    %Setting{
      key: [:context, :max_decision_context_tokens],
      label: "Decision context token budget",
      description:
        "Maximum tokens allocated for decision graph context injected into agent prompts.",
      why_change:
        "Increase if agents need richer decision history for informed choices. Decrease if decisions are simple.",
      type: :number,
      default: 1024,
      range: {256, 8192},
      step: 256,
      unit: "tokens",
      tab: "Intelligence",
      section: "Context Window"
    },
    %Setting{
      key: [:context, :reserved_output_tokens],
      label: "Reserved output tokens",
      description:
        "Tokens reserved for model output generation. Subtracted from context window before filling with input.",
      why_change:
        "Increase if agents are generating truncated outputs. Decrease to fit more context into the window.",
      type: :number,
      default: 4096,
      range: {1024, 16384},
      step: 512,
      unit: "tokens",
      tab: "Intelligence",
      section: "Context Window"
    },

    # ── Intelligence: Conversations ───────────────────────────────────
    %Setting{
      key: [:conversations, :inactivity_timeout_ms],
      label: "Conversation inactivity timeout",
      description:
        "How long a multi-agent conversation can be idle before it's automatically closed.",
      why_change:
        "Increase for conversations where agents take time between turns. Decrease to reclaim resources faster.",
      type: :duration,
      default: 60_000,
      range: {10_000, 600_000},
      step: 5_000,
      unit: "ms",
      tab: "Intelligence",
      section: "Conversations"
    },
    %Setting{
      key: [:conversations, :max_personas],
      label: "Max conversation personas",
      description:
        "Maximum number of personas (agents) that can participate in a single conversation.",
      why_change:
        "Increase for rich multi-perspective discussions. Decrease if conversations are too noisy or expensive.",
      type: :number,
      default: 6,
      range: {2, 12},
      step: 1,
      tab: "Intelligence",
      section: "Conversations"
    },
    %Setting{
      key: [:conversations, :default_max_rounds],
      label: "Default conversation rounds",
      description:
        "Default number of turn rounds in a spawned conversation if not specified by the tool call.",
      why_change: "Increase for deeper deliberations. Decrease for quick brainstorms.",
      type: :number,
      default: 8,
      range: {2, 30},
      step: 1,
      tab: "Intelligence",
      section: "Conversations"
    },
    %Setting{
      key: [:conversations, :default_strategy],
      label: "Default turn strategy",
      description: "Default turn-taking strategy for new conversations.",
      why_change:
        "Use 'weighted' for quality-focused discussions. Use 'facilitator' for structured debates.",
      type: :select,
      options: ["round_robin", "weighted", "facilitator"],
      default: "round_robin",
      tab: "Intelligence",
      section: "Conversations"
    },

    # ── Intelligence: Decision Graph ──────────────────────────────────
    # NOTE: decisions.enabled, decisions.enforce_pre_edit, and decisions.auto_log_commits
    # are defined in config.ex defaults but not yet read by any module at runtime.
    # They'll be added here once the decision graph respects these flags.

    %Setting{
      key: [:decisions, :cascade_threshold],
      label: "Cascade confidence threshold",
      description:
        "Minimum confidence (0-100) for a decision to propagate through the graph to dependent nodes.",
      why_change:
        "Lower to propagate more decisions (broader but noisier). Raise for higher-confidence-only propagation.",
      type: :number,
      default: 50,
      range: {0, 100},
      step: 5,
      tab: "Intelligence",
      section: "Decision Graph"
    },
    %Setting{
      key: [:decisions, :pulse_stale_days],
      label: "Decision staleness threshold",
      description: "Days after which a decision node is considered stale and may need review.",
      why_change:
        "Decrease for fast-moving projects where decisions go stale quickly. Increase for stable codebases.",
      type: :number,
      default: 7,
      range: {1, 90},
      step: 1,
      unit: "days",
      tab: "Intelligence",
      section: "Decision Graph"
    },
    %Setting{
      key: [:decisions, :pulse_confidence_threshold],
      label: "Pulse low-confidence threshold",
      description:
        "Confidence score (0-100) below which the pulse monitor flags a decision for review.",
      why_change:
        "Lower to only flag very uncertain decisions. Raise to catch more borderline decisions.",
      type: :number,
      default: 50,
      range: {0, 100},
      step: 5,
      tab: "Intelligence",
      section: "Decision Graph"
    },

    # ── Intelligence: Monitoring & Health ─────────────────────────────
    %Setting{
      key: [:repo, :watch_enabled],
      label: "File watcher enabled",
      description:
        "Whether the file system watcher monitors the project directory for external changes.",
      why_change:
        "Disable if the watcher is causing performance issues or conflicting with your editor's file watching.",
      type: :toggle,
      default: true,
      tab: "Intelligence",
      section: "Monitoring & Health"
    },

    # ── Safety: Permissions & Auto-Approve ────────────────────────────
    %Setting{
      key: [:permissions, :auto_approve],
      label: "Auto-approved tools",
      description: "Tools that agents can execute without asking for user approval.",
      why_change:
        "Add more tools for faster autonomous operation. Remove tools that you want to manually approve each time.",
      type: :tag_list,
      default: ["file_read", "file_search", "content_search", "directory_list"],
      tab: "Safety",
      section: "Permissions & Auto-Approve"
    },
    %Setting{
      key: [:shell, :allowlist_enabled],
      label: "Shell allowlist enabled",
      description:
        "When enabled, agents can only run shell commands that appear in the allowlist.",
      why_change:
        "Enable for production-adjacent environments where you want strict command control.",
      type: :toggle,
      default: false,
      tab: "Safety",
      section: "Shell Allowlist"
    },
    %Setting{
      key: [:shell, :allowlist],
      label: "Shell command allowlist",
      description: "Commands agents are allowed to execute when the allowlist is enabled.",
      why_change:
        "Add commands your agents need (e.g., docker, kubectl). Remove commands you want to block.",
      type: :tag_list,
      default:
        ~w(mix elixir iex git cat head tail ls find grep rg sed awk echo mkdir cp mv touch node npm npx yarn bun cargo rustc go python python3 pip ruby gem),
      tab: "Safety",
      section: "Shell Allowlist"
    }
  ]

  @settings_by_key Map.new(@settings, fn s ->
                     key = s.key |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
                     {key, s}
                   end)
  @tabs @settings |> Enum.map(& &1.tab) |> Enum.uniq()
  @settings_by_tab Enum.group_by(@settings, & &1.tab)

  @doc "All defined settings."
  @spec all() :: [Setting.t()]
  def all, do: @settings

  @doc "Ordered list of tab names."
  @spec tabs() :: [String.t()]
  def tabs, do: @tabs

  @doc "Settings for a given tab, grouped by section."
  @spec by_tab(String.t()) :: %{String.t() => [Setting.t()]}
  def by_tab(tab) do
    @settings_by_tab
    |> Map.get(tab, [])
    |> Enum.group_by(& &1.section)
  end

  @doc "Look up a setting by its dot-path string key."
  @spec by_key(String.t()) :: Setting.t() | nil
  def by_key(key_string), do: Map.get(@settings_by_key, key_string)

  @doc "Return the default value for a setting key."
  @spec default_for(String.t()) :: term()
  def default_for(key_string) do
    case by_key(key_string) do
      %Setting{default: default} -> default
      nil -> nil
    end
  end

  @doc """
  Read all current setting values from Config, falling back to registry defaults.

  Returns a flat map keyed by dot-path strings (e.g., `"teams.consensus.quorum"`).
  """
  @spec current_values() :: %{String.t() => term()}
  def current_values do
    config = Loomkin.Config.all()

    Map.new(@settings, fn setting ->
      key_str = key_string(setting.key)
      raw = get_nested(config, setting.key)
      value = if is_nil(raw), do: setting.default, else: raw
      {key_str, value}
    end)
  end

  @doc "Validate a value against a setting's type and constraints."
  @spec validate(Setting.t(), term()) :: :ok | {:error, String.t()}
  def validate(%Setting{type: :number} = s, value) when is_number(value) do
    validate_range(s, value)
  end

  def validate(%Setting{type: :number}, _value), do: {:error, "must be a number"}

  def validate(%Setting{type: :duration} = s, value) when is_number(value) do
    validate_range(s, value)
  end

  def validate(%Setting{type: :duration}, _value), do: {:error, "must be a number"}

  def validate(%Setting{type: :currency} = s, value) when is_number(value) do
    validate_range(s, value)
  end

  def validate(%Setting{type: :currency}, _value), do: {:error, "must be a number"}

  def validate(%Setting{type: :toggle}, value) when is_boolean(value), do: :ok
  def validate(%Setting{type: :toggle}, _value), do: {:error, "must be true or false"}

  def validate(%Setting{type: :select, options: options}, value) when is_binary(value) do
    if value in options, do: :ok, else: {:error, "must be one of: #{Enum.join(options, ", ")}"}
  end

  def validate(%Setting{type: :select}, _value), do: {:error, "must be a string"}

  def validate(%Setting{type: :tag_list}, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: :ok, else: {:error, "all items must be strings"}
  end

  def validate(%Setting{type: :tag_list}, _value), do: {:error, "must be a list"}

  @doc "Convert a key path to a dot-separated string."
  @spec key_string(list(atom())) :: String.t()
  def key_string(key_path) do
    key_path |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
  end

  # --- Helpers ---

  defp validate_range(%Setting{range: nil}, _value), do: :ok

  defp validate_range(%Setting{range: {min, max}}, value) do
    if value >= min and value <= max do
      :ok
    else
      {:error, "must be between #{min} and #{max}"}
    end
  end

  defp get_nested(map, []), do: map

  defp get_nested(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      value -> get_nested(value, rest)
    end
  end

  defp get_nested(_map, _keys), do: nil
end
