alias Loomkin.Backlog

items = [
  # === Active Sprint: Workspace Experience Overhaul ===
  # -- Layout & Proximity --
  %{
    title: "Move user input + concierge area closer together",
    description: "Currently at opposite ends of the UI. Should feel like a conversation, not shouting across a room.",
    status: :todo,
    priority: 1,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["layout", "proximity", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Concierge-orchestrated feel",
    description: "Interface should feel like the concierge is coordinating everything. The concierge IS the UI host.",
    status: :todo,
    priority: 1,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["layout", "concierge", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Concierge UI control tools",
    description: "Give the concierge agent tools to control the interface (open sidebar panels, highlight agents, push notifications, etc.)",
    status: :todo,
    priority: 2,
    category: "tools",
    epic: "Workspace Experience Overhaul",
    tags: ["concierge", "tools", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Concierge leadership tools",
    description: "Real-time agent activity streams, interrupt/redirect mid-task, work-in-progress inspection, conflict auto-resolution, file access guardrails (read-only vs read-write scoping per agent).",
    status: :todo,
    priority: 2,
    category: "tools",
    epic: "Workspace Experience Overhaul",
    tags: ["concierge", "leadership", "tools", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Kin-requested reinforcements",
    description: "Kin should have a tool to request that the concierge spin up an additional kin to help them. The requesting kin specifies the role/skillset they need and the new kin is spawned in tight communication with the requester — paired up, sharing context, collaborating directly on the same problem.",
    status: :todo,
    priority: 2,
    category: "tools",
    epic: "Workspace Experience Overhaul",
    tags: ["reinforcement", "collaboration", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Work isolation principle",
    description: "New work must never block on or collide with in-progress work. If a new initiative overlaps with what a team is already doing, either: (a) queue it until they finish, or (b) spin up a separate team on a separate branch so they can't conflict. The concierge must assess overlap before assigning new work.",
    status: :todo,
    priority: 2,
    category: "architecture",
    epic: "Workspace Experience Overhaul",
    tags: ["isolation", "branches", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Kill switch for teams",
    description: "Concierge needs the ability to halt an entire team immediately if they're going down the wrong road. Stop all agents, revert their uncommitted changes, and reassess. This should be a single action, not dissolve + manual cleanup.",
    status: :todo,
    priority: 1,
    category: "tools",
    epic: "Workspace Experience Overhaul",
    tags: ["kill-switch", "safety", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },
  # -- Kin Cards & Teams --
  %{
    title: "Kin focus cards as tabbed modals",
    description: "When you click a kin card, it opens a rich modal with tabs: Activity tab (what they're doing now, recent actions), Decisions tab (decisions made by this kin), Files tab (files created/modified), History tab (completed tasks, past work).",
    status: :todo,
    priority: 2,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["kin-cards", "modals", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Team card grouping",
    description: "Kin cards should be logically grouped by team, not a flat list.",
    status: :todo,
    priority: 2,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["kin-cards", "teams", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Kin cards show work summary",
    description: "At-a-glance view of what each agent has accomplished.",
    status: :todo,
    priority: 3,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["kin-cards", "summary", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :quick
  },
  # -- Visual Cues --
  %{
    title: "Visual cues for agent state",
    description: "At-a-glance indicators showing what's happening: agent working/idle/blocked, task progress, team health. Color, animation, iconography that communicates status without reading text.",
    status: :todo,
    priority: 2,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["visual", "status", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Activity pulse animations",
    description: "Subtle visual indicators (glow, pulse, typing animation) showing that agents are actively working, not just sitting there.",
    status: :todo,
    priority: 3,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["visual", "animation", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :quick
  },
  # -- Dynamic Sidebar --
  %{
    title: "Sidebar for live work surfaces",
    description: "Brainstorm sessions, reports, detailed results appear dynamically as they happen.",
    status: :todo,
    priority: 2,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["sidebar", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Sidebar complements, never duplicates",
    description: "Don't repeat what's already visible in the main area.",
    status: :todo,
    priority: 3,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["sidebar", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :quick
  },
  %{
    title: "Sidebar auto-appears on relevant content",
    description: "When relevant content emerges (brainstorm starts, report ready), sidebar slides in automatically.",
    status: :todo,
    priority: 3,
    category: "ui",
    epic: "Workspace Experience Overhaul",
    tags: ["sidebar", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },
  # -- Personality & Entertainment --
  %{
    title: "Kin personality system",
    description: "Agents get ridiculous human names from pop culture (book characters, TV characters, etc.).",
    status: :todo,
    priority: 3,
    category: "fun",
    epic: "Workspace Experience Overhaul",
    tags: ["personality", "names", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "In-character chat bubbles",
    description: "Kin periodically make remarks in character based on what they're doing. Cute, immersive, doesn't impact work.",
    status: :todo,
    priority: 4,
    category: "fun",
    epic: "Workspace Experience Overhaul",
    tags: ["personality", "chat", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Subtle entertainment value",
    description: "The interface should be fun to watch, not just functional.",
    status: :todo,
    priority: 4,
    category: "fun",
    epic: "Workspace Experience Overhaul",
    tags: ["personality", "entertainment", "active-sprint"],
    created_by: "concierge",
    scope_estimate: :session
  },

  # === System Prompts & Agent Tools ===
  # -- System Prompt Improvements --
  %{
    title: "Research-only role enforcement",
    description: "Researcher kin system prompts must prohibit file_write/file_edit. Currently 'researcher' is a suggestion, not a constraint. Kin ignore boundaries.",
    status: :todo,
    priority: 1,
    category: "system-prompts",
    epic: "System Prompts & Agent Tools",
    tags: ["enforcement", "researcher", "roles"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Region claiming actually enforced",
    description: "System prompts tell kin to claim regions, but there's no enforcement. Conflicts happen anyway. Need hard guardrails, not polite suggestions.",
    status: :todo,
    priority: 2,
    category: "system-prompts",
    epic: "System Prompts & Agent Tools",
    tags: ["enforcement", "regions", "conflicts"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Task focus discipline",
    description: "Kin wander off-task (Builder was supposed to design backlog schema, ended up reading UI component files). Prompts need stronger 'stay in your lane' instructions tied to the specific task assigned.",
    status: :todo,
    priority: 2,
    category: "system-prompts",
    epic: "System Prompts & Agent Tools",
    tags: ["focus", "discipline", "prompts"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Corrective message responsiveness",
    description: "When the concierge sends a redirect/correction, kin need to actually process and respond to it. Currently messages may be ignored or arrive too late.",
    status: :todo,
    priority: 2,
    category: "system-prompts",
    epic: "System Prompts & Agent Tools",
    tags: ["messages", "redirect", "responsiveness"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Read vs write intent distinction",
    description: "Conflict detection currently fires on reads AND writes. System needs to distinguish 'agent is reading a file to understand it' from 'agent is editing a file.' Only the latter should trigger conflicts.",
    status: :todo,
    priority: 3,
    category: "system-prompts",
    epic: "System Prompts & Agent Tools",
    tags: ["conflicts", "file-access", "intent"],
    created_by: "concierge",
    scope_estimate: :session
  },
  # -- Concierge Tool Additions --
  %{
    title: "Inspect agent activity tool",
    description: "Tool to see what an agent is currently doing (last N tool calls, current file, thinking state).",
    status: :todo,
    priority: 2,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["concierge", "inspection", "observability"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Redirect agent tool",
    description: "Tool to interrupt an agent mid-task and give them new instructions without dissolving the whole team.",
    status: :todo,
    priority: 2,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["concierge", "redirect", "control"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Scope agent file access tool",
    description: "Tool to set per-agent file boundaries (read-only dirs, write-allowed dirs).",
    status: :todo,
    priority: 3,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["concierge", "file-access", "scoping"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Kill team with revert tool",
    description: "Dissolve team + git checkout on all uncommitted changes they made. One action.",
    status: :todo,
    priority: 1,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["concierge", "kill-switch", "revert"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Kin reinforcement request tool",
    description: "Kin-facing tool that sends a structured request to the concierge: 'I need a [role] to help me with [problem].' Concierge can approve/deny and spawn the paired kin.",
    status: :todo,
    priority: 2,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["reinforcement", "kin-tool", "collaboration"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Branch isolation tool",
    description: "Spin up a team on a fresh git branch so they can't conflict with main working tree.",
    status: :todo,
    priority: 2,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["branches", "isolation", "git"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  # -- Agent Tool Review --
  %{
    title: "Audit existing kin tools",
    description: "Catalog every tool available to each role. Are there tools kin have that they shouldn't? Tools they need but don't have?",
    status: :todo,
    priority: 2,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["audit", "tools", "roles"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Role-specific tool filtering",
    description: "Researchers shouldn't have file_write. Reviewers shouldn't have file_edit. Tools should be filtered by role at spawn time.",
    status: :todo,
    priority: 1,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["enforcement", "tools", "roles"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Task-scoped tool context",
    description: "When a kin picks up a task, their tool access should reflect the task scope (e.g., 'you may only read files in lib/loomkin_web/' for a UI research task).",
    status: :todo,
    priority: 3,
    category: "tools",
    epic: "System Prompts & Agent Tools",
    tags: ["scoping", "tools", "tasks"],
    created_by: "concierge",
    scope_estimate: :campaign
  },

  # === Infrastructure & Reliability ===
  # -- Context & Memory --
  %{
    title: "Fix keeper negativity bias",
    description: "Keepers currently only store failure logs. Need auto-offload hooks for positive work products (research results, design decisions, implementation summaries).",
    status: :todo,
    priority: 2,
    category: "infrastructure",
    epic: "Infrastructure & Reliability",
    tags: ["keepers", "context", "memory"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Data persistence across restarts",
    description: "Task results, conversation synthesis, and keeper data must survive restarts.",
    status: :todo,
    priority: 1,
    category: "infrastructure",
    epic: "Infrastructure & Reliability",
    tags: ["persistence", "restarts", "durability"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  # -- Long-Horizon Autonomy --
  %{
    title: "Review Epic-16 long-horizon coding patterns",
    description: "Evaluate docs/epic-16-long-horizon-coding.md patterns for adoption.",
    status: :todo,
    priority: 3,
    category: "infrastructure",
    epic: "Infrastructure & Reliability",
    tags: ["epic-16", "long-horizon", "autonomy"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Solve Vertex AI quota exhaustion",
    description: "Multi-agent teams burn through quota. Need rate limiting or model rotation.",
    status: :todo,
    priority: 2,
    category: "infrastructure",
    epic: "Infrastructure & Reliability",
    tags: ["quota", "vertex-ai", "rate-limiting"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Agent context recovery after restart",
    description: "When agents restart, they should be able to resume work from keepers/backlog.",
    status: :todo,
    priority: 2,
    category: "infrastructure",
    epic: "Infrastructure & Reliability",
    tags: ["recovery", "restart", "context"],
    created_by: "concierge",
    scope_estimate: :campaign
  },

  # === Icebox ===
  %{
    title: "Decision graph cleanup",
    description: "Prune the 47+ stale goals, or deprecate the graph in favor of the backlog system.",
    status: :icebox,
    priority: 4,
    category: "infrastructure",
    epic: "Infrastructure & Reliability",
    tags: ["decision-graph", "cleanup", "deprecation"],
    created_by: "concierge",
    scope_estimate: :session
  },
  %{
    title: "Agent effectiveness metrics",
    description: "Track task completion rates, artifact production rates, and other quality metrics.",
    status: :icebox,
    priority: 4,
    category: "infrastructure",
    epic: "Infrastructure & Reliability",
    tags: ["metrics", "effectiveness", "tracking"],
    created_by: "concierge",
    scope_estimate: :campaign
  },
  %{
    title: "Cross-team collaboration improvements",
    description: "Improve how agents on different teams share context and coordinate work.",
    status: :icebox,
    priority: 4,
    category: "infrastructure",
    epic: "Infrastructure & Reliability",
    tags: ["cross-team", "collaboration"],
    created_by: "concierge",
    scope_estimate: :campaign
  }
]

results = Enum.map(items, fn attrs ->
  case Backlog.create_item(attrs) do
    {:ok, item} -> {:ok, item.title}
    {:error, changeset} -> {:error, attrs.title, changeset.errors}
  end
end)

successes = Enum.count(results, &match?({:ok, _}, &1))
failures = Enum.filter(results, &match?({:error, _, _}, &1))

IO.puts("\n=== BACKLOG IMPORT RESULTS ===")
IO.puts("Imported: #{successes} items")
if length(failures) > 0 do
  IO.puts("Failed: #{length(failures)} items:")
  Enum.each(failures, fn {:error, title, errors} ->
    IO.puts("  - #{title}: #{inspect(errors)}")
  end)
end

IO.puts("\nSummary by status:")
IO.inspect(Backlog.get_summary())
