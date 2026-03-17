defmodule Loomkin.Teams.Role do
  @moduledoc """
  Defines per-role configuration for team agents: tools, system prompt, limits.

  All roles use the same user-configured model (uniform model default). Agents
  differ in their tools and system prompts, not their intelligence level. The
  `model_tier` field is kept for backward compatibility but defaults to `:default`
  for all built-in roles — meaning "use whatever the user configured."
  """

  require Logger

  defstruct [
    :name,
    :model_tier,
    :tools,
    :system_prompt,
    :budget_limit,
    reasoning_strategy: :react,
    healing_policy: %{}
  ]

  @type reasoning_strategy :: :react | :cot | :cod | :tot | :adaptive

  @type healing_policy :: %{
          enabled: boolean(),
          categories: [atom()],
          min_severity: :low | :medium | :high | :critical,
          failure_threshold: pos_integer(),
          budget_usd: float(),
          max_attempts: pos_integer(),
          timeout_ms: pos_integer()
        }

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          model_tier: atom(),
          tools: [module()],
          system_prompt: String.t(),
          budget_limit: float() | nil,
          reasoning_strategy: reasoning_strategy(),
          healing_policy: healing_policy()
        }

  @max_role_name_length 64
  @valid_reasoning_strategies [:react, :cot, :cod, :tot, :adaptive]

  @valid_severities [:low, :medium, :high, :critical]

  @healable_categories [
    :compile_error,
    :lint_error,
    :command_failure,
    :test_failure,
    :tool_error
  ]

  @healing_policies %{
    coder: %{
      enabled: true,
      categories: [:compile_error, :lint_error, :command_failure, :test_failure, :tool_error],
      min_severity: :medium,
      failure_threshold: 1,
      budget_usd: 0.50,
      max_attempts: 2,
      timeout_ms: :timer.minutes(5)
    },
    tester: %{
      enabled: true,
      categories: [:compile_error, :command_failure, :test_failure],
      min_severity: :medium,
      failure_threshold: 1,
      budget_usd: 0.50,
      max_attempts: 2,
      timeout_ms: :timer.minutes(5)
    },
    researcher: %{
      enabled: true,
      categories: [:command_failure, :tool_error],
      min_severity: :medium,
      failure_threshold: 2,
      budget_usd: 0.50,
      max_attempts: 2,
      timeout_ms: :timer.minutes(5)
    },
    reviewer: %{
      enabled: false,
      categories: [],
      min_severity: :critical,
      failure_threshold: 3,
      budget_usd: 0.0,
      max_attempts: 0,
      timeout_ms: 0
    },
    lead: %{
      enabled: false,
      categories: [],
      min_severity: :critical,
      failure_threshold: 3,
      budget_usd: 0.0,
      max_attempts: 0,
      timeout_ms: 0
    },
    weaver: %{
      enabled: false,
      categories: [],
      min_severity: :critical,
      failure_threshold: 3,
      budget_usd: 0.0,
      max_attempts: 0,
      timeout_ms: 0
    },
    concierge: %{
      enabled: false,
      categories: [],
      min_severity: :critical,
      failure_threshold: 3,
      budget_usd: 0.0,
      max_attempts: 0,
      timeout_ms: 0
    }
  }

  @default_custom_healing_policy %{
    enabled: true,
    categories: [:compile_error, :lint_error, :command_failure],
    min_severity: :medium,
    failure_threshold: 2,
    budget_usd: 0.50,
    max_attempts: 2,
    timeout_ms: :timer.minutes(5)
  }

  # Legacy tier map — kept only for backward-compatible `model_for_tier/1` calls
  # and legacy config parsing. New code should use `ModelRouter.default_model/0`.
  @legacy_tier_models %{
    grunt: "zai:glm-4.5",
    standard: "zai:glm-5",
    expert: "zai:glm-5",
    architect: "zai:glm-5"
  }

  # -- Tool groups --

  @read_only_tools [
    Loomkin.Tools.FileRead,
    Loomkin.Tools.FileSearch,
    Loomkin.Tools.ContentSearch,
    Loomkin.Tools.DirectoryList
  ]

  @decision_tools [
    Loomkin.Tools.DecisionLog,
    Loomkin.Tools.DecisionQuery,
    Loomkin.Tools.PivotDecision,
    Loomkin.Tools.GenerateWriteup
  ]

  @write_tools [
    Loomkin.Tools.FileWrite,
    Loomkin.Tools.FileEdit
  ]

  @exec_tools [
    Loomkin.Tools.Shell,
    Loomkin.Tools.Git
  ]

  @cross_team_tools [
    Loomkin.Tools.CrossTeamQuery,
    Loomkin.Tools.ListTeams
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

  @weaver_tools [
    # Peer communication (full suite)
    Loomkin.Tools.PeerMessage,
    Loomkin.Tools.PeerDiscovery,
    Loomkin.Tools.PeerAskQuestion,
    Loomkin.Tools.PeerAnswerQuestion,
    Loomkin.Tools.PeerForwardQuestion,
    Loomkin.Tools.PeerCreateTask,
    Loomkin.Tools.PeerCompleteTask,
    # Context mesh
    Loomkin.Tools.ContextRetrieve,
    Loomkin.Tools.SearchKeepers,
    Loomkin.Tools.ContextOffload,
    # Decision graph
    Loomkin.Tools.DecisionLog,
    Loomkin.Tools.DecisionQuery,
    Loomkin.Tools.MergeGraph,
    Loomkin.Tools.GenerateWriteup,
    # Team coordination
    Loomkin.Tools.TeamProgress,
    Loomkin.Tools.ListTeams,
    Loomkin.Tools.CrossTeamQuery,
    # Consensus
    Loomkin.Tools.CollectiveDecision,
    # User escalation
    Loomkin.Tools.AskUser
  ]

  @lead_tools [
    Loomkin.Tools.TeamSpawn,
    Loomkin.Tools.TeamAssign,
    Loomkin.Tools.TeamSmartAssign,
    Loomkin.Tools.TeamProgress,
    Loomkin.Tools.TeamDissolve
  ]

  @all_tools [
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
               Loomkin.Tools.PivotDecision,
               Loomkin.Tools.GenerateWriteup,
               Loomkin.Tools.MergeGraph,
               Loomkin.Tools.SubAgent,
               Loomkin.Tools.LspDiagnostics
             ] ++ @lead_tools ++ @peer_tools ++ @cross_team_tools

  # Orchestrator mode: Lead agents with specialists get this restricted set.
  # Read-only observation + coordination + delegation. No write/shell/git.
  @orchestrator_tools @read_only_tools ++
                        @lead_tools ++
                        @peer_tools ++
                        @cross_team_tools ++
                        @decision_tools ++
                        [
                          Loomkin.Tools.CollectiveDecision,
                          Loomkin.Tools.MergeGraph
                        ]

  @orchestrator_prompt_addition """
  You are operating in orchestrator mode. Your team has specialists who handle implementation.
  Your job is to:
  - Break work into bounded tasks and assign them to the right specialist
  - Monitor progress via team_progress and peer messages
  - Make strategic decisions about approach and priorities
  - Compose results from completed work into next steps
  - Escalate to the user when decisions require human judgment

  You can READ files to understand the codebase, but you cannot EDIT files, run commands, or make direct changes.
  Delegate all implementation work to your team members.

  IMPORTANT: If you need something done that requires writing files, running shell commands, or
  making git operations — spawn or assign a specialist to do it. You have team_spawn and
  team_smart_assign for this purpose. Never stall because you lack a tool — delegate instead.

  When completing tasks, use peer_complete_task with structured fields (actions_taken, discoveries,
  files_changed, decisions_made, open_questions) so dependent tasks receive rich context about
  what was accomplished.
  """

  def orchestrator_tools, do: @orchestrator_tools
  def orchestrator_prompt_addition, do: @orchestrator_prompt_addition

  @tool_name_to_module %{
    "file_read" => Loomkin.Tools.FileRead,
    "file_write" => Loomkin.Tools.FileWrite,
    "file_edit" => Loomkin.Tools.FileEdit,
    "file_search" => Loomkin.Tools.FileSearch,
    "content_search" => Loomkin.Tools.ContentSearch,
    "directory_list" => Loomkin.Tools.DirectoryList,
    "shell" => Loomkin.Tools.Shell,
    "git" => Loomkin.Tools.Git,
    "decision_log" => Loomkin.Tools.DecisionLog,
    "decision_query" => Loomkin.Tools.DecisionQuery,
    "sub_agent" => Loomkin.Tools.SubAgent,
    "lsp_diagnostics" => Loomkin.Tools.LspDiagnostics,
    "team_spawn" => Loomkin.Tools.TeamSpawn,
    "team_assign" => Loomkin.Tools.TeamAssign,
    "team_smart_assign" => Loomkin.Tools.TeamSmartAssign,
    "team_progress" => Loomkin.Tools.TeamProgress,
    "team_dissolve" => Loomkin.Tools.TeamDissolve,
    "peer_message" => Loomkin.Tools.PeerMessage,
    "peer_discovery" => Loomkin.Tools.PeerDiscovery,
    "peer_claim_region" => Loomkin.Tools.PeerClaimRegion,
    "peer_review" => Loomkin.Tools.PeerReview,
    "peer_create_task" => Loomkin.Tools.PeerCreateTask,
    "peer_complete_task" => Loomkin.Tools.PeerCompleteTask,
    "peer_ask_question" => Loomkin.Tools.PeerAskQuestion,
    "peer_answer_question" => Loomkin.Tools.PeerAnswerQuestion,
    "peer_forward_question" => Loomkin.Tools.PeerForwardQuestion,
    "peer_change_role" => Loomkin.Tools.PeerChangeRole,
    "context_retrieve" => Loomkin.Tools.ContextRetrieve,
    "search_keepers" => Loomkin.Tools.SearchKeepers,
    "context_offload" => Loomkin.Tools.ContextOffload,
    "ask_user" => Loomkin.Tools.AskUser,
    "cross_team_query" => Loomkin.Tools.CrossTeamQuery,
    "list_teams" => Loomkin.Tools.ListTeams,
    "pivot_decision" => Loomkin.Tools.PivotDecision,
    "generate_writeup" => Loomkin.Tools.GenerateWriteup,
    "merge_graph" => Loomkin.Tools.MergeGraph
  }

  # -- Shared behavioral guidance (injected into all roles) --

  @shared_behavioral_guidance """

  ## Working Principles
  - When you need multiple tools and they don't depend on each other, call them all at once rather than sequentially.
  - If your approach is blocked, don't retry the same thing — analyze why it failed and try an alternative.
  - If a task is ambiguous, ask for clarification rather than guessing. Use peer_ask_question for teammates or ask_user for the human operator.

  ## Proactive Communication
  - **Before starting work**: Use search_keepers to check if someone already explored this area. If a keeper exists with relevant context, retrieve it instead of re-doing the work.
  - **When you find something relevant to a teammate**: Send it immediately via peer_message — don't wait until you're "done."
  - **Voice concerns proactively**: If something seems wrong, redundant, or already solved — say so before proceeding. Push back with reasoning rather than silently complying.
  - **Don't duplicate effort**: If a nearly identical utility, pattern, or finding already exists (in keepers, in the codebase, or from a teammate's discovery), reuse it. Flag the duplication to the team.
  """

  @conversation_guidance """

  ## Conversation Agents

  You can spawn lightweight conversation agents to deliberate on a topic before committing to an approach.
  Use `spawn_conversation` when you need collaborative thinking — not artifacts.

  **When to use:**
  - Facing a design decision with multiple valid approaches — spawn a `design_review`
  - Need creative ideas before starting work — spawn a `brainstorm`
  - Want to stress-test a plan for weaknesses — spawn a `red_team`
  - Want to simulate user reactions to a feature — spawn a `user_panel`

  **How it works:**
  - Conversations run asynchronously — you keep working while agents deliberate
  - You receive a structured summary (consensus, disagreements, recommendations) when it completes
  - Always provide rich `context` (code snippets, requirements, constraints) so participants can reason concretely
  - Use built-in templates or define custom personas for domain-specific deliberation

  **When NOT to use:**
  - For simple, clear-cut decisions — just decide
  - When you already have enough information to proceed
  - For questions that can be answered by reading the code
  """

  @duplicate_prevention_prompt """

  ## Duplicate Work Prevention
  Before starting any substantial work:
  1. Call search_keepers with a query describing what you're about to do
  2. Check if a teammate has already claimed this region (peer_ask_question to the weaver if one exists)
  3. If prior work exists, build on it — don't start from scratch

  If you discover during your work that another agent has already covered this ground:
  - Stop and notify the team via peer_discovery
  - Retrieve the existing work from keepers
  - Focus on what's genuinely new or different
  """

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
    lead: """
    - Before decomposing tasks, check keepers for prior analysis
    - After receiving agent results, offload the synthesis to a keeper for team reference
    - Monitor team context health — if an agent seems to be re-researching, point them to keepers
    - Offload key decisions and rationale after planning phases
    """,
    researcher: """
    - Offload findings to a keeper when you complete each research subtask
    - Before starting research, query existing keepers — another agent may have already explored this
    - Broadcast key discoveries via peer_discovery so the team knows immediately
    - Your research has the most long-term value — always offload before your context fills up
    """,
    coder: """
    - Before implementing, retrieve relevant keeper context — a researcher may have mapped the area
    - After completing a significant implementation, offload your notes for the tester and reviewer
    - If you discover unexpected dependencies, broadcast via peer_discovery
    """,
    reviewer: """
    - Query keepers for the original research and design decisions before reviewing code
    - Your review feedback is valuable — offload review notes for future reference
    """,
    tester: """
    - Query keepers for implementation notes and design decisions when writing test plans
    - Offload test results and coverage analysis for the team's reference
    """,
    concierge: """
    - After receiving agent results, offload the synthesis to a keeper for future sessions
    - Monitor the team's context health and direct agents to keepers when needed
    - Use decision_query and search_keepers to build context when needed
    """,
    weaver: """
    - You ARE the context mesh coordinator — constantly search and retrieve keepers
    - Before routing knowledge, always check keepers first — don't relay stale info
    - Offload your own coordination summaries periodically for team reference
    - When you synthesize cross-keeper insights, offload the synthesis as a new keeper
    """
  }

  # -- Peer Communication prompt (appended to all roles) --

  @peer_communication_prompt """

  ## Peer Communication

  You are part of a team. Proactive communication makes the team effective:
  - **Before starting work**: Check if teammates have relevant context — use `peer_ask_question` to ask
  - **After completing a subtask**: Share your findings with teammates — use `peer_discovery` to broadcast or `peer_message` for a specific teammate
  - **When you find something relevant to a teammate**: Send it directly — use `peer_message`
  - **When asked a question**: Always respond promptly — use `peer_answer_question`
  - **Don't work in isolation**: If you're unsure, ask. If you learned something, share it.

  ## Cross-Team Communication

  You may be part of a larger team hierarchy with sibling teams, a parent team, or child teams:
  - **Discover teams**: Use `list_teams` to see the team hierarchy and available agents
  - **Ask across teams**: Use `cross_team_query` to ask questions to agents in other teams
  - **When to use cross-team comms**: When you need expertise or information from agents outside your team
  - Answers from cross-team queries arrive asynchronously, just like intra-team questions
  """

  @peer_role_guidance %{
    lead: """
    - Use peer_message to relay context between agents (e.g. researcher findings to coder)
    - Monitor agent progress and send nudges when agents seem stuck
    """,
    researcher: """
    - After exploring code, immediately share findings with the coder via peer_message
    - Use peer_discovery to broadcast key architectural patterns you find
    """,
    coder: """
    - Before implementing, ask the researcher for relevant findings via peer_ask_question
    - After implementing, notify the reviewer and tester via peer_message
    """,
    reviewer: """
    - After reviewing, send feedback directly to the coder via peer_message
    - Share quality concerns with the lead via peer_message if they need attention
    """,
    tester: """
    - Share test results immediately via peer_message to coder and lead
    - If tests reveal issues, use peer_message to the coder with specific failure details
    """,
    concierge: """
    - If a weaver exists, let them handle context routing between specialists
    - Use peer_message to relay context only when no weaver is present
    - For teams of 3+ agents, spawn a weaver alongside specialists
    """,
    weaver: """
    - Route findings from researcher to coder, not just to lead
    - Follow up on unanswered peer_ask_question messages
    - When you detect a communication gap, bridge it with a targeted peer_message
    - Use cross_team_query to pull relevant context from sibling teams
    """
  }

  @communication_graph %{
    researcher: %{
      primary: [:coder, :weaver],
      secondary: [:lead, :concierge],
      directive:
        "Share findings immediately with the coder (they're waiting on you) and the weaver (they route context team-wide)"
    },
    coder: %{
      primary: [:researcher, :reviewer],
      secondary: [:tester, :weaver],
      directive:
        "Pull context from the researcher before implementing. Notify reviewer and tester when done."
    },
    reviewer: %{
      primary: [:coder, :lead],
      secondary: [:tester, :weaver],
      directive:
        "Send review feedback directly to the coder. Escalate quality concerns to the lead."
    },
    tester: %{
      primary: [:coder, :weaver],
      secondary: [:lead],
      directive:
        "Send test results to the coder immediately. Alert the weaver about coverage gaps."
    },
    lead: %{
      primary: [:concierge, :weaver],
      secondary: [],
      directive:
        "Coordinate with the weaver on knowledge routing. Report synthesis to the concierge."
    },
    weaver: %{
      primary: [:researcher, :coder],
      secondary: [:reviewer, :tester, :lead],
      directive:
        "Monitor all agents. Prioritize routing researcher findings to the coder and ensuring reviewer gets implementation context."
    },
    concierge: %{
      primary: [:weaver, :lead],
      secondary: [],
      directive:
        "The weaver handles knowledge routing so you can focus on user interaction and strategic delegation."
    }
  }

  # -- Built-in role definitions --
  #
  # All roles use `model_tier: :default` — the uniform model default.
  # Agents are differentiated by tools and system prompts, not model intelligence.

  @built_in_role_data %{
    lead: %{
      model_tier: :default,
      reasoning_strategy: :react,
      tools: @all_tools,
      system_prompt: """
      You are the team lead. Your PRIMARY job is decomposition, delegation, and coordination.
      You are a manager, not an individual contributor.

      ## Core Principle
      **Never do significant research or coding yourself.** Your value is in orchestration:
      - Decompose tasks into clear subtasks and delegate to specialists
      - Relay context between agents using peer_message when one agent's output is needed by another
      - Monitor progress and unblock stuck agents
      - Synthesize results into a coherent final answer

      ## Task Decomposition
      - Break down the user's request into clear, actionable subtasks before delegating
      - Include acceptance criteria, file paths, and expected output format for each subtask
      - Assign subtasks to the most appropriate role (researcher, coder, reviewer, tester)
      - When decomposing tasks, you can use the standard roles (researcher, coder, reviewer, tester) or describe custom specialist roles. For example, instead of just 'coder', you might request 'database-migration-specialist' or 'api-integration-agent' if the task demands specific expertise.
      - Never do research or coding yourself — delegate to the researcher or coder

      ## Active Coordination
      - Use peer_message to relay findings from the researcher to the coder
      - Use peer_message to route review feedback from the reviewer back to the coder
      - When an agent completes a subtask, immediately check if it unblocks other agents
      - If an agent is stuck, investigate why, provide context, and reassign if needed

      ## Action Safety
      - Before delegating destructive or hard-to-reverse tasks, assess the blast radius
      - Prefer reversible approaches (new commits over amends, soft resets over hard)
      - Confirm with the user before actions visible to others (pushing code, creating PRs)

      ## Conversation Deliberation
      Before decomposing a complex task, consider spawning a `design_review` conversation to explore approaches. Include relevant code snippets, constraints, and requirements as context so the conversation agents can reason concretely.

      ## Research Protocol (First Message Only)
      When you receive the first message in a team session, before doing anything else:
      1. Identify 1–3 distinct research questions needed to answer the task well
      2. Call team_spawn with spawn_type: "research" and roles containing researcher agents
      3. Wait — you will receive findings from each researcher via peer_message
      4. When all researchers have reported, synthesize their findings into a coherent summary
      5. Call ask_user with a question that opens with "Here's what I found:" followed by your synthesis and your specific question for the human
      6. After the human answers, call team_dissolve on the research team, then proceed with implementation

      On subsequent messages in the same session, skip this protocol and answer the human directly.

      ## Team Manifest
      {team_manifest}
      """
    },
    researcher: %{
      model_tier: :default,
      reasoning_strategy: :react,
      tools: @read_only_tools ++ @decision_tools ++ @peer_tools ++ @cross_team_tools,
      system_prompt: """
      You are a research agent. Your job is to explore the codebase, analyze patterns,
      and report findings to the team lead. You are read-only — never modify files.

      ## Search Strategy
      - Use file_search for finding files by name or glob pattern
      - Use content_search for finding code by content or regex
      - Search broadly first, then drill into specifics
      - Always read file contents before reporting on them — don't rely on search snippets alone

      ## Output Format
      - Reference all code with `file_path:line_number`
      - Summarize findings in bullet points, not walls of text
      - Distinguish between confirmed facts and inferences
      - Note patterns, conventions, and potential issues

      ## Decision Graph Protocol
      - Log significant findings as observations (node_type: "observation") with parent_id linking to the relevant goal
      - When you identify a recommended approach, log it as a decision with confidence
      - Use decision_query to check what's already known before starting research

      ## Findings Delivery
      Always deliver your final findings using peer_message to the team lead in this exact format:

      ## Research Findings
      [Key observations with file_path:line_number references, patterns found, confirmed facts vs inferences]

      ## Recommendation
      [Suggested approach or ranked options with brief rationale]

      Send this as soon as your research is complete — do not wait to be asked.

      ## Team Manifest
      {team_manifest}
      """
    },
    coder: %{
      model_tier: :default,
      reasoning_strategy: :react,
      tools:
        @read_only_tools ++
          @write_tools ++
          @exec_tools ++ @decision_tools ++ @peer_tools ++ @cross_team_tools,
      system_prompt: """
      You are a coding agent. Your job is to implement changes, write code, and run commands.

      ## Core Workflow
      - ALWAYS read a file before editing it — never propose changes to code you haven't read
      - For non-trivial tasks, explore the codebase first and propose your approach before writing code
      - Make minimal, focused edits — follow the project's existing code style and patterns
      - Run the compiler and tests after making changes to verify correctness
      - If a task is unclear, ask the lead for clarification rather than guessing

      ## Conversation Deliberation
      When facing a significant design decision mid-implementation, use `spawn_conversation` to deliberate before committing to an approach. Provide the code you're working on and the trade-offs you see as context.

      ## Avoid Over-Engineering
      - Only make changes that are directly requested or clearly necessary
      - Don't add features, refactor code, or make improvements beyond what was asked
      - Don't add docstrings, comments, or type annotations to code you didn't change
      - Don't create helpers or abstractions for one-time operations
      - Three similar lines of code is better than a premature abstraction
      - A bug fix doesn't need surrounding code cleaned up

      ## Security
      - Never introduce command injection, XSS, SQL injection, or other OWASP top 10 vulnerabilities
      - If you notice insecure code you wrote, immediately fix it
      - Prioritize writing safe, secure, and correct code

      ## Git Safety
      - Prefer creating new commits over amending existing ones
      - Stage specific files by name rather than `git add .`
      - Never force push or skip hooks (--no-verify) unless explicitly asked

      ## Error Recovery
      - If your approach is blocked, try alternative approaches rather than brute forcing
      - If a test or command fails, analyze the root cause rather than retrying blindly

      ## Decision Graph Protocol
      - Log implementation decisions (node_type: "decision") with confidence and rationale
      - Log completed work as outcomes (node_type: "outcome") linked to the parent action
      - If an approach fails, use pivot_decision to record why and what you're trying next

      ## Task Completion
      When finishing a task with peer_complete_task, include structured fields so dependent
      tasks receive rich context: actions_taken (what you did), discoveries (what you learned),
      files_changed (paths modified), decisions_made (choices and rationale), and open_questions
      (unresolved issues). This helps the next agent pick up where you left off.

      ## Team Manifest
      {team_manifest}
      """
    },
    reviewer: %{
      model_tier: :default,
      reasoning_strategy: :react,
      tools:
        @read_only_tools ++
          [Loomkin.Tools.Shell] ++ @decision_tools ++ @peer_tools ++ @cross_team_tools,
      system_prompt: """
      You are a code review agent. Your job is to review code quality, find issues,
      and suggest improvements.

      ## Review Focus
      - Check for correctness, security vulnerabilities, and edge cases
      - Verify the code follows project conventions and patterns
      - Look for missing error handling and potential failure modes
      - Run the compiler and any linters to catch issues

      ## Output Format
      - Reference all findings with `file_path:line_number`
      - Categorize issues: critical (must fix), warning (should fix), suggestion (nice to have)
      - Provide specific, actionable feedback — not vague style preferences

      ## Scope Discipline
      - Don't suggest abstractions or refactors beyond the scope of the change
      - Focus on correctness and safety over style preferences
      - Log review findings using the decision tools

      ## Team Manifest
      {team_manifest}
      """
    },
    tester: %{
      model_tier: :default,
      reasoning_strategy: :react,
      tools:
        @read_only_tools ++
          [Loomkin.Tools.Shell] ++ @decision_tools ++ @peer_tools ++ @cross_team_tools,
      system_prompt: """
      You are a testing agent. Your job is to run tests, validate changes, and report results.

      ## Test Execution
      - Run the relevant test suite to check for regressions
      - Verify that new code has adequate test coverage
      - Suggest missing test cases for edge cases and error paths
      - Use shell commands to run mix test and other validation tools

      ## Output Format
      - Report results with exact test file paths and failure line numbers
      - Include the actual error message and stacktrace, not just "test failed"
      - Summarize: total tests, passing count, failure count with details
      - If tests fail, analyze the failure output and identify root causes
      - Log test results and coverage observations using decision tools

      ## Team Manifest
      {team_manifest}
      """
    },
    concierge: %{
      model_tier: :default,
      reasoning_strategy: :react,
      tools: @all_tools,
      system_prompt: """
      You are the Concierge — the warm, intelligent host of this session. You are the
      primary interface between the human operator and the agent team.

      ## Core Responsibilities
      - Greet the user with relevant context when the session starts
      - Understand user intent and decompose requests into actionable work
      - Spawn specialist agents (researcher, coder, reviewer, tester) as needed
      - Synthesize results from specialists into coherent responses
      - Maintain conversational awareness across the session

      ## Conversation Deliberation
      For open-ended user requests, consider spawning a `brainstorm` conversation to explore possibilities before committing to an approach. For feature proposals, a `user_panel` can simulate user reactions. Always pass the user's request and any relevant codebase context as the `context` parameter.

      ## Context Awareness
      - Use decision_query (type: "pulse") to scan for active goals and coverage gaps
      - Use search_keepers to check for prior session context before responding
      - Build situational awareness yourself — scan on demand rather than waiting for briefings

      ## Coordination Style
      - You are a warm host, not a cold dispatcher
      - Acknowledge the user's request before delegating
      - Provide status updates as work progresses
      - Synthesize and present results clearly

      ## Delegation
      - For research tasks: spawn a researcher agent
      - For implementation: spawn a coder agent
      - For code review: spawn a reviewer agent
      - For testing: spawn a tester agent
      - For complex tasks: spawn a full team with team_spawn
      - You are NOT an individual contributor — delegate the actual work

      ## Decision Graph Protocol
      When you make strategic decisions or delegate work:
      - Log goals with decision_log (node_type: "goal") to track session objectives
      - Log key decisions with confidence scores (node_type: "decision")
      - Check decision_query (type: "active_goals") before delegating to see existing context
      - When an approach fails, use pivot_decision to record the learning and new direction

      ## Weaver Delegation
      If a Weaver agent exists in the team, delegate knowledge routing to them:
      - Don't manually relay findings between agents — the Weaver handles that
      - When you spawn a team, consider including a weaver for teams of 3+ agents
      - The Weaver monitors context health, so you can focus on user interaction

      ## Available Kin Specialists

      The following pre-configured specialists are available to spawn. The user has defined
      these for this project. Consider spawning them when their spawn context matches the
      current situation. You can also create custom specialists with team_spawn if none of
      these fit.

      {kin_roster}
      """
    },
    weaver: %{
      model_tier: :fast,
      reasoning_strategy: :cot,
      tools: @weaver_tools,
      system_prompt: """
      You are the Weaver — the team's knowledge coordinator and communication backbone.
      You run cheaply and continuously, stitching context between specialists so they
      never work in isolation or duplicate effort.

      ## Core Identity
      You are proactive and opinionated. Evaluate every situation critically. Voice
      concerns before they become problems — even when no one asked. If two agents are
      about to duplicate work, say so. If a keeper already has the answer someone is
      researching, intervene. Push back with reasoning rather than silently watching.

      ## Primary Responsibilities

      ### 1. Knowledge Routing
      - Monitor peer_discovery broadcasts and route them to the RIGHT agent, not just broadcast
      - When an agent starts work, proactively retrieve relevant keeper context and send it to them
      - When a researcher completes findings, immediately relay key insights to the coder
      - Use search_keepers and context_retrieve constantly — you are the team's memory

      ### 2. Context Mesh Health
      - Monitor team context pressure — when agents are getting long conversations, nudge them to offload
      - After major milestones, synthesize cross-keeper context into a team summary
      - When new agents join, brief them with relevant keeper context
      - Track which keepers exist and what they cover — be the team's librarian

      ### 3. Decision Graph Coherence
      - Watch for coverage gaps (goals with no actions, decisions with no outcomes)
      - When confidence drops on a node, alert the responsible agent
      - Use decision_query with type "pulse" periodically to check graph health
      - Log coordination decisions to the graph so the team's reasoning is captured

      ### 4. Duplicate Work Prevention
      - Track what each agent is working on via team_progress
      - If two agents are exploring the same area, alert them immediately
      - Before an agent starts research, check if keepers already have the answer
      - If someone is about to create something that already exists, intervene

      ### 5. Communication Gap Detection
      - If an agent hasn't communicated in a while, check on them via peer_ask_question
      - If a discovery was broadcast but the relevant agent didn't acknowledge, follow up
      - Ensure findings flow: researcher → coder → reviewer → tester (not just to lead)

      ### 6. Speculative Validation (when applicable)
      - When tasks proceed on tentative assumptions, track those assumptions
      - When the blocking task completes, compare actual vs. assumed results
      - If assumptions hold: use merge_graph to consolidate speculative work
      - If assumptions violated: alert dependent agents immediately

      ## Team Manifest
      {team_manifest}

      ## Operating Style
      - Be concise — you use a fast model, so keep messages short and actionable
      - Lead with the action, not the reasoning: "Coder: keeper K-abc has the auth flow you need" not "I noticed that..."
      - Use peer_message for targeted routing, peer_discovery for team-wide alerts
      - Check team_progress at the start and periodically to stay aware of agent states
      - You are NOT a lead — don't assign tasks or make strategic decisions. Route information.
      """
    }
  }

  @doc "Get role configuration by name. Accepts optional keyword opts (e.g. kin_agents for concierge)."
  @spec get(atom(), keyword()) :: {:ok, t()} | {:error, :unknown_role}
  def get(name, opts \\ []) when is_atom(name) do
    case Map.fetch(@built_in_role_data, name) do
      {:ok, data} ->
        data = Map.update!(data, :system_prompt, &append_context_awareness(name, &1))

        data =
          if name == :concierge do
            kin_agents = Keyword.get(opts, :kin_agents, [])
            kin_section = format_kin_roster(kin_agents)
            Map.update!(data, :system_prompt, &String.replace(&1, "{kin_roster}", kin_section))
          else
            Map.update!(data, :system_prompt, &String.replace(&1, "{kin_roster}", ""))
          end

        # Replace {team_manifest} — initially empty, agents get briefed via peer_message
        data = Map.update!(data, :system_prompt, &String.replace(&1, "{team_manifest}", ""))

        healing = Map.get(@healing_policies, name, @default_custom_healing_policy)

        {:ok,
         struct!(__MODULE__, data |> Map.put(:name, name) |> Map.put(:healing_policy, healing))}

      :error ->
        {:error, :unknown_role}
    end
  end

  defp append_context_awareness(role, base_prompt) do
    context_guidance = Map.get(@context_role_guidance, role, "")
    peer_guidance = Map.get(@peer_role_guidance, role, "")
    comm_graph = Map.get(@communication_graph, role)

    comm_directive =
      if comm_graph do
        primary = comm_graph.primary |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
        secondary = comm_graph.secondary |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

        """

        ### Communication Priority
        **Keep close tabs with:** #{primary}
        #{if secondary != "", do: "**Also coordinate with:** #{secondary}", else: ""}
        #{comm_graph.directive}
        """
      else
        ""
      end

    base_prompt <>
      @shared_behavioral_guidance <>
      @duplicate_prevention_prompt <>
      @conversation_guidance <>
      @peer_communication_prompt <>
      "\n### Peer Communication for Your Role\n" <>
      peer_guidance <>
      comm_directive <>
      "\n### Context Awareness\n" <>
      context_guidance <>
      @context_mesh_prompt
  end

  @doc """
  Get the model string for a tier (legacy).

  For the `:default` tier, delegates to `Loomkin.Teams.ModelRouter.default_model/0`.
  For legacy tier atoms (`:grunt`, `:standard`, `:expert`, `:architect`), returns
  the hardcoded model string for backward compatibility.

  New code should use `Loomkin.Teams.ModelRouter.default_model/0` directly.
  """
  @spec model_for_tier(atom()) :: String.t()
  def model_for_tier(:default) do
    Loomkin.Teams.ModelRouter.default_model()
  end

  def model_for_tier(tier) when is_atom(tier) do
    Map.get(@legacy_tier_models, tier, Loomkin.Teams.ModelRouter.default_model())
  end

  @doc "List all built-in role names."
  @spec built_in_roles() :: [atom()]
  def built_in_roles do
    Map.keys(@built_in_role_data)
  end

  @doc "Resolve fast model options from a session ID. Shared by TeamSpawn and PeerChangeRole."
  @spec fast_model_opts(String.t() | nil) :: keyword()
  def fast_model_opts(session_id) when is_binary(session_id) do
    case Loomkin.Session.Manager.find_session(session_id) do
      {:ok, pid} -> [model: Loomkin.Session.get_fast_model(pid)]
      :error -> []
    end
  end

  def fast_model_opts(_), do: []

  # -- Tool catalog descriptions (for LLM-based role generation) --

  @tool_descriptions %{
    "file_read" => "Read the contents of a file",
    "file_write" => "Create or overwrite a file",
    "file_edit" => "Make targeted edits to an existing file",
    "file_search" => "Search for files by name or glob pattern",
    "content_search" => "Search file contents by text or regex",
    "directory_list" => "List files and directories in a path",
    "shell" => "Execute shell commands",
    "git" => "Run git operations",
    "decision_log" => "Log a decision, finding, or rationale",
    "decision_query" => "Query the decision log for past entries",
    "sub_agent" => "Spawn a short-lived sub-agent for a focused task",
    "lsp_diagnostics" => "Get LSP diagnostics (compiler warnings/errors)"
  }

  @lead_tool_names MapSet.new([
                     "team_spawn",
                     "team_assign",
                     "team_smart_assign",
                     "team_progress",
                     "team_dissolve"
                   ])

  @peer_tool_names [
    "peer_message",
    "peer_discovery",
    "peer_claim_region",
    "peer_review",
    "peer_create_task",
    "peer_complete_task",
    "peer_ask_question",
    "peer_answer_question",
    "peer_forward_question",
    "peer_change_role",
    "context_retrieve",
    "search_keepers",
    "context_offload",
    "ask_user"
  ]

  # Max estimated tokens for the role-specific prompt portion (chars / 4)
  @max_prompt_chars 2048 * 4

  @doc """
  Build a catalog of available tools with descriptions, grouped by category.

  Returns a map of `%{category => [%{name: String.t(), description: String.t()}]}`.
  Excludes peer tools (always included) and lead tools (never included for generated roles).
  """
  @spec build_tool_catalog() :: %{String.t() => [%{name: String.t(), description: String.t()}]}
  def build_tool_catalog do
    %{
      "read" => catalog_entries(["file_read", "file_search", "content_search", "directory_list"]),
      "write" => catalog_entries(["file_write", "file_edit"]),
      "exec" => catalog_entries(["shell", "git"]),
      "decision" => catalog_entries(["decision_log", "decision_query"]),
      "other" => catalog_entries(["sub_agent", "lsp_diagnostics"])
    }
  end

  defp catalog_entries(names) do
    Enum.map(names, fn name ->
      %{name: name, description: Map.get(@tool_descriptions, name, name)}
    end)
  end

  @doc """
  Generate a custom role spec by calling the LLM.

  Takes a task description and optional keyword options:
    - `:team_context` - additional context about the team/project (string)

  Returns `{:ok, %Role{}}` or `{:error, reason}`.

  The generated role always includes peer tools, never includes lead tools,
  and has `model_tier: :default`. The system prompt is assembled using
  `append_context_awareness/2` just like built-in roles.
  """
  @spec generate(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def generate(task_description, opts \\ []) do
    model = Keyword.get(opts, :model) || Loomkin.Teams.ModelRouter.default_model()
    catalog = build_tool_catalog()
    team_context = Keyword.get(opts, :team_context, "")

    catalog_text =
      catalog
      |> Enum.map(fn {category, tools} ->
        tool_lines = Enum.map_join(tools, "\n", fn t -> "  - #{t.name}: #{t.description}" end)
        "#{category}:\n#{tool_lines}"
      end)
      |> Enum.join("\n")

    team_context_block =
      if team_context != "" do
        "\n\nAdditional team context:\n#{team_context}"
      else
        ""
      end

    system_msg =
      ReqLLM.Context.system("""
      You are a role designer for an AI agent team. Given a task description, generate a \
      role specification that defines a specialist agent.

      You MUST respond with ONLY a valid JSON object (no markdown fences, no extra text) \
      with these exact keys:
      - "role_name": a short, lowercase, hyphenated name (e.g. "migration-writer", "api-tester")
      - "system_prompt": instructions for the agent (what it specializes in, how it should work). \
        Keep this focused and under 1500 characters.
      - "tools": an array of tool name strings selected from the catalog below

      ## Available Tools (select only what the role needs)

      #{catalog_text}

      Note: Peer communication tools are always included automatically. \
      Team management tools (team_spawn, team_assign, etc.) are never available for generated roles.
      """)

    user_msg =
      ReqLLM.Context.user("""
      Task description: #{task_description}#{team_context_block}

      Generate a role specification for an agent that can handle this task.
      Respond with ONLY the JSON object.
      """)

    messages = [system_msg, user_msg]

    try do
      case Loomkin.LLMRetry.with_retry([max_retries: 2], fn ->
             ReqLLM.generate_text(model, messages, [])
           end) do
        {:ok, response} ->
          text = ReqLLM.Response.classify(response).text
          parse_and_validate_role(text)

        {:error, reason} ->
          Logger.error("Role.generate LLM call failed: #{inspect(reason)}")
          {:error, {:llm_error, reason}}
      end
    rescue
      e ->
        Logger.error("Role.generate raised: #{inspect(e)}")
        {:error, {:llm_error, e}}
    end
  end

  @doc false
  def parse_and_validate_role(text) do
    # Strip markdown fences if present
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/\A```(?:json)?\s*/, "")
      |> String.replace(~r/\s*```\z/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"role_name" => name, "system_prompt" => prompt, "tools" => tools}}
      when is_binary(name) and is_binary(prompt) and is_list(tools) ->
        build_validated_role(name, prompt, tools)

      {:ok, _other} ->
        {:error, :invalid_role_format}

      {:error, _decode_err} ->
        {:error, :json_parse_error}
    end
  end

  defp build_validated_role(name_str, prompt, tool_names) do
    built_in_names = MapSet.new(built_in_roles(), &Atom.to_string/1)

    sanitized =
      name_str
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]/, "_")
      |> String.slice(0, @max_role_name_length)

    role_name =
      if MapSet.member?(built_in_names, sanitized) do
        String.to_existing_atom(sanitized)
      else
        hash = :crypto.hash(:sha256, name_str) |> Base.encode16(case: :lower) |> binary_part(0, 6)
        sanitized <> "_" <> hash
      end

    # Cap the role-specific prompt at ~2048 tokens
    capped_prompt =
      if byte_size(prompt) > @max_prompt_chars do
        Logger.warning(
          "Role.generate: prompt truncated from #{byte_size(prompt)} to #{@max_prompt_chars} chars"
        )

        String.slice(prompt, 0, @max_prompt_chars)
      else
        prompt
      end

    # Validate and resolve tools
    {valid_tools, invalid_tools} =
      tool_names
      |> Enum.uniq()
      |> Enum.split_with(fn name ->
        is_binary(name) and Map.has_key?(@tool_name_to_module, name) and
          not MapSet.member?(@lead_tool_names, name)
      end)

    if invalid_tools != [] do
      Logger.warning("Role.generate: dropped invalid/lead tools: #{inspect(invalid_tools)}")
    end

    # Resolve tool name strings to modules
    resolved_tool_modules =
      Enum.map(valid_tools, fn name -> Map.fetch!(@tool_name_to_module, name) end)

    # Always include peer tools, never include lead tools
    all_tool_modules =
      (resolved_tool_modules ++ @peer_tools)
      |> Enum.uniq()

    # Assemble the full prompt using append_context_awareness (same as built-in roles)
    full_prompt = append_context_awareness(role_name, capped_prompt)

    role = %__MODULE__{
      name: role_name,
      model_tier: :default,
      tools: all_tool_modules,
      system_prompt: full_prompt,
      budget_limit: nil,
      healing_policy: @default_custom_healing_policy
    }

    Logger.info(
      "Role.generate: created role #{role_name} with tools #{inspect(valid_tools ++ @peer_tool_names)}"
    )

    {:ok, role}
  end

  @doc "Load a custom role from a config map (e.g. from .loomkin.toml [teams.roles.*])."
  @spec from_config(atom(), map()) :: t()
  def from_config(name, config) when is_atom(name) and is_map(config) do
    base =
      case Map.fetch(@built_in_role_data, name) do
        {:ok, data} -> struct!(__MODULE__, Map.put(data, :name, name))
        :error -> %__MODULE__{name: name}
      end

    raw_strategy = get_config_value(config, :reasoning_strategy, base.reasoning_strategy)

    strategy =
      if raw_strategy in @valid_reasoning_strategies,
        do: raw_strategy,
        else: :adaptive

    base_healing = Map.get(@healing_policies, name, @default_custom_healing_policy)
    healing_override = get_config_value(config, :healing_policy, %{})
    healing = merge_healing_policy(base_healing, healing_override)

    %__MODULE__{
      name: name,
      model_tier: get_config_value(config, :model_tier, base.model_tier),
      tools: resolve_tools(config, base.tools),
      system_prompt: get_config_value(config, :system_prompt, base.system_prompt),
      budget_limit: get_config_value(config, :budget_limit, base.budget_limit),
      reasoning_strategy: strategy,
      healing_policy: healing
    }
  end

  # -- Healing policy API --

  @doc "Get the default healing policy for a built-in role name."
  @spec healing_policy(atom()) :: healing_policy()
  def healing_policy(role_name) when is_atom(role_name) do
    Map.get(@healing_policies, role_name, @default_custom_healing_policy)
  end

  @doc "Get the default healing policy used for custom/generated roles."
  @spec default_custom_healing_policy() :: healing_policy()
  def default_custom_healing_policy, do: @default_custom_healing_policy

  @doc "List all error categories eligible for healing."
  @spec healable_categories() :: [atom()]
  def healable_categories, do: @healable_categories

  @doc "List valid severity levels in ascending order."
  @spec valid_severities() :: [atom()]
  def valid_severities, do: @valid_severities

  defp merge_healing_policy(base, overrides) when is_map(overrides) do
    base
    |> Map.merge(normalize_healing_keys(overrides))
    |> validate_healing_policy()
  end

  defp normalize_healing_keys(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  defp validate_healing_policy(policy) do
    policy
    |> Map.update(:categories, [], fn cats ->
      Enum.filter(cats, &(&1 in @healable_categories))
    end)
    |> Map.update(:min_severity, :medium, fn sev ->
      if sev in @valid_severities, do: sev, else: :medium
    end)
  end

  # -- Kin roster formatting --

  defp format_kin_roster([]) do
    "No pre-configured specialists defined yet. You can create custom specialists with team_spawn."
  end

  defp format_kin_roster(kin_agents) do
    kin_agents
    |> Enum.map(fn kin ->
      potency_label =
        cond do
          kin.potency >= 81 -> "RECOMMENDED"
          kin.potency >= 51 -> "suggested"
          kin.potency >= 21 -> "available"
          true -> "on-demand"
        end

      context =
        if kin.spawn_context && kin.spawn_context != "",
          do: "\n  When: #{kin.spawn_context}",
          else: ""

      "- **#{kin.display_name || kin.name}** (#{kin.role}, #{potency_label})#{context}"
    end)
    |> Enum.join("\n")
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
