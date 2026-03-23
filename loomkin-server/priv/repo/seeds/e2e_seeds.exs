# E2E test seed data
# Run with: mix run priv/repo/seeds/e2e_seeds.exs

alias Loomkin.Accounts
alias Loomkin.Session.Persistence
alias Loomkin.Backlog

IO.puts("Seeding e2e test data...")

# Clean up test registration user from previous runs
case Accounts.get_user_by_email("newuser-e2e@loomkin.test") do
  nil -> :ok
  user ->
    Loomkin.Repo.delete(user)
    IO.puts("  Cleaned up previous registration test user")
end

# Create test user
{:ok, user} =
  case Accounts.get_user_by_email("e2e@loomkin.test") do
    nil ->
      Accounts.register_user(%{
        email: "e2e@loomkin.test",
        password: "e2e_test_password_123!"
      })

    user ->
      # Ensure password matches in case it was changed
      case Accounts.update_user_password(user, %{password: "e2e_test_password_123!"}) do
        {:ok, {updated_user, _tokens}} -> {:ok, updated_user}
        {:ok, updated_user} -> {:ok, updated_user}
        {:error, _} -> {:ok, user}
      end
  end

IO.puts("  Created/found user: #{user.email}")

# ---------------------------------------------------------------------------
# Session 1: Primary test session with agent_name messages
# ---------------------------------------------------------------------------
{:ok, session} =
  Persistence.create_session(%{
    title: "E2E Test Session",
    model: "anthropic:claude-sonnet-4-20250514",
    project_path: "/tmp/e2e-test-project",
    status: :active,
    user_id: user.id
  })

IO.puts("  Created session: #{session.id}")

{:ok, _} =
  Persistence.save_message(%{
    session_id: session.id,
    role: :user,
    content: "Hello, can you help me set up a new project?"
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session.id,
    role: :assistant,
    content:
      "Of course! I'd be happy to help you set up a new project. What kind of project would you like to create?",
    agent_name: "Architect"
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session.id,
    role: :user,
    content: "A Phoenix LiveView application with authentication."
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session.id,
    role: :assistant,
    content:
      "I'll scaffold the Phoenix project with LiveView and phx.gen.auth. Let me set that up for you.",
    agent_name: "Architect"
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session.id,
    role: :assistant,
    content:
      "I've reviewed the project structure. The authentication module looks solid. I'd suggest adding rate limiting to the login endpoint.",
    agent_name: "Reviewer"
  })

IO.puts("  Added 5 messages to session (with agent_name)")

# Update costs for session 1
Persistence.update_costs(session.id, 1250, 890, 0.0034)

# ---------------------------------------------------------------------------
# Session 2: Higher cost session for cost tracking tests
# ---------------------------------------------------------------------------
{:ok, session2} =
  Persistence.create_session(%{
    title: "Code Review Session",
    model: "anthropic:claude-sonnet-4-20250514",
    project_path: "/tmp/e2e-review-project",
    status: :active,
    user_id: user.id
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session2.id,
    role: :user,
    content: "Review the authentication module for security issues."
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session2.id,
    role: :assistant,
    content:
      "I've completed a thorough security review of the authentication module. Here are my findings: the session token rotation is correctly implemented, but I recommend adding CSRF protection to the API endpoints.",
    agent_name: "Security Auditor"
  })

Persistence.update_costs(session2.id, 15_420, 8_750, 0.0487)
IO.puts("  Created session 2: Code Review Session (cost: $0.0487)")

# ---------------------------------------------------------------------------
# Session 3: Archived session with high token usage
# ---------------------------------------------------------------------------
{:ok, session3} =
  Persistence.create_session(%{
    title: "Data Pipeline Build",
    model: "anthropic:claude-sonnet-4-20250514",
    project_path: "/tmp/e2e-pipeline-project",
    status: :active,
    user_id: user.id
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session3.id,
    role: :user,
    content: "Build an ETL pipeline for processing CSV files."
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session3.id,
    role: :assistant,
    content:
      "I'll create a GenStage-based ETL pipeline with three stages: CSV parser, data transformer, and database loader.",
    agent_name: "Builder"
  })

Persistence.update_costs(session3.id, 42_100, 28_300, 0.1412)
Persistence.archive_session(Persistence.get_session(session3.id))
IO.puts("  Created session 3: Data Pipeline Build (archived, cost: $0.1412)")

# ---------------------------------------------------------------------------
# Session 4: Minimal session for testing empty/low cost
# ---------------------------------------------------------------------------
{:ok, session4} =
  Persistence.create_session(%{
    title: "Quick Question",
    model: "anthropic:claude-sonnet-4-20250514",
    project_path: "/tmp/e2e-test-project",
    status: :active,
    user_id: user.id
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session4.id,
    role: :user,
    content: "What is the difference between GenServer and Agent?"
  })

{:ok, _} =
  Persistence.save_message(%{
    session_id: session4.id,
    role: :assistant,
    content: "GenServer is a general-purpose server process, while Agent is a simpler abstraction focused on state management."
  })

Persistence.update_costs(session4.id, 320, 180, 0.001)
IO.puts("  Created session 4: Quick Question (cost: $0.001)")

# ---------------------------------------------------------------------------
# Team with agents in various states
# ---------------------------------------------------------------------------
team_id = Ecto.UUID.generate()

alias Loomkin.Teams.Context, as: TeamContext
alias Loomkin.Teams.TableRegistry

# Ensure the ETS table exists for this team
TableRegistry.create_table(team_id)

TeamContext.register_agent(team_id, "lead-architect", %{
  role: "lead",
  status: "active"
})

TeamContext.register_agent(team_id, "frontend-dev", %{
  role: "specialist",
  status: "idle"
})

TeamContext.register_agent(team_id, "backend-dev", %{
  role: "specialist",
  status: "active"
})

TeamContext.register_agent(team_id, "qa-engineer", %{
  role: "specialist",
  status: "blocked"
})

IO.puts("  Created team #{String.slice(team_id, 0, 8)} with 4 agents")

# Link team to a session and ensure it has the latest updated_at
# so setup-session.yaml opens this session first (sorted by updated_at DESC)
Process.sleep(1_000)
Persistence.update_session(Persistence.get_session(session.id), %{team_id: team_id})
IO.puts("  Linked team to session: #{session.id}")

# ---------------------------------------------------------------------------
# Backlog items
# ---------------------------------------------------------------------------
backlog_items = [
  %{
    title: "Set up project structure",
    description: "Initialize Phoenix project with LiveView and authentication",
    status: :done,
    priority: 1,
    category: "setup",
    created_by: "e2e-seed"
  },
  %{
    title: "Implement user dashboard",
    description: "Create the main dashboard view with session list and team overview",
    status: :in_progress,
    priority: 2,
    category: "feature",
    created_by: "e2e-seed"
  },
  %{
    title: "Add model provider settings",
    description: "Settings page for configuring LLM model providers",
    status: :todo,
    priority: 3,
    category: "feature",
    created_by: "e2e-seed"
  }
]

for item_attrs <- backlog_items do
  {:ok, item} = Backlog.create_item(item_attrs)
  IO.puts("  Created backlog item: #{item.title}")
end

IO.puts("\nE2E seed data complete!")
