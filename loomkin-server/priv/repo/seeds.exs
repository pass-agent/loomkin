# Script for populating the database with sample social data.
#
# Run with: mix run priv/repo/seeds.exs
# Safe to run multiple times — checks for existing data first.

alias Loomkin.Repo
alias Loomkin.Accounts.User
alias Loomkin.Social

import Ecto.Query

IO.puts("\n🌱 Seeding Loomkin social data...\n")

# ── Helper to create users directly (bypassing email validation for seeds) ──

defmodule Seeds do
  def find_or_create_user(attrs) do
    case Repo.get_by(User, email: attrs.email) do
      nil ->
        %User{}
        |> Ecto.Changeset.change(attrs)
        |> Ecto.Changeset.put_change(:hashed_password, Bcrypt.hash_pwd_salt("password123456"))
        |> Ecto.Changeset.put_change(:confirmed_at, NaiveDateTime.utc_now(:second))
        |> Repo.insert!()

      user ->
        user
    end
  end

  def ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
  end
end

# ── Create sample users ──────────────────────────────────────────────

alice =
  Seeds.find_or_create_user(%{
    email: "alice@example.com",
    username: "alice",
    display_name: "Alice Chen"
  })

bob =
  Seeds.find_or_create_user(%{
    email: "bob@example.com",
    username: "bob",
    display_name: "Bob Rivera"
  })

carol =
  Seeds.find_or_create_user(%{
    email: "carol@example.com",
    username: "carol",
    display_name: "Carol Okonkwo"
  })

dave =
  Seeds.find_or_create_user(%{
    email: "dave@example.com",
    username: "dave",
    display_name: "Dave Park"
  })

IO.puts("✓ Users: alice, bob, carol, dave")

# ── Create sample snippets ───────────────────────────────────────────

snippets_data = [
  # Skills
  {alice,
   %{
     title: "Debug Detective",
     description:
       "Systematic debugging skill using binary search isolation. Teaches agents to narrow down failures by halving the problem space, checking assumptions, and documenting each elimination step.",
     type: :skill,
     visibility: :public,
     tags: ["debugging", "methodology", "systematic"],
     content: %{
       "frontmatter" => %{
         "name" => "debug-detective",
         "description" => "Binary search debugging methodology"
       },
       "body" =>
         "## Purpose\nTeach agents systematic debugging via binary search isolation.\n\n## Core Workflow\n1. Reproduce the failure\n2. Identify the last known good state\n3. Binary search between good and bad\n4. Document each elimination step"
     }
   }},
  {bob,
   %{
     title: "React Component Reviewer",
     description:
       "Specialized reviewer for React components. Checks for accessibility, performance anti-patterns, proper hook usage, and component composition best practices.",
     type: :skill,
     visibility: :public,
     tags: ["react", "review", "frontend", "accessibility"],
     content: %{
       "frontmatter" => %{
         "name" => "react-reviewer",
         "description" => "React component review specialist"
       },
       "body" =>
         "## Purpose\nReview React components for quality, accessibility, and performance.\n\n## Checks\n- Hook dependency arrays\n- Memoization appropriateness\n- ARIA attributes\n- Render performance"
     }
   }},
  {carol,
   %{
     title: "API Design Architect",
     description:
       "Guides agents through RESTful API design decisions including resource naming, pagination strategies, error response formats, and versioning approaches.",
     type: :skill,
     visibility: :public,
     tags: ["api", "rest", "architecture", "design"],
     content: %{
       "frontmatter" => %{
         "name" => "api-architect",
         "description" => "RESTful API design guidance"
       },
       "body" =>
         "## Purpose\nGuide API design with consistent patterns.\n\n## Decisions\n- Resource naming conventions\n- Pagination: cursor vs offset\n- Error envelope format\n- Versioning strategy"
     }
   }},
  {dave,
   %{
     title: "Elixir Pattern Matcher",
     description:
       "Deep expertise in Elixir pattern matching, guard clauses, and multi-clause function design. Helps refactor conditional logic into clean pattern-matched solutions.",
     type: :skill,
     visibility: :public,
     tags: ["elixir", "patterns", "refactoring"],
     content: %{
       "frontmatter" => %{
         "name" => "elixir-patterns",
         "description" => "Pattern matching expertise for Elixir"
       },
       "body" =>
         "## Purpose\nRefactor conditionals into pattern-matched function clauses.\n\n## Techniques\n- Multi-head functions\n- Guard clause combinations\n- Struct matching\n- Binary pattern matching"
     }
   }},
  {alice,
   %{
     title: "Test Pyramid Strategist",
     description:
       "Helps teams build the right mix of unit, integration, and e2e tests. Focuses on testing behavior over implementation, with practical heuristics for when to use each layer.",
     type: :skill,
     visibility: :public,
     tags: ["testing", "strategy", "quality"],
     content: %{
       "frontmatter" => %{
         "name" => "test-strategist",
         "description" => "Test pyramid design and strategy"
       },
       "body" =>
         "## Purpose\nDesign effective test suites with the right layer balance.\n\n## Heuristics\n- Unit: pure functions, edge cases\n- Integration: boundaries, contracts\n- E2E: critical user paths only"
     }
   }},

  # Prompts
  {bob,
   %{
     title: "Code Review Checklist",
     description:
       "Structured code review prompt that covers security, performance, readability, and maintainability. Produces actionable feedback organized by severity.",
     type: :prompt,
     visibility: :public,
     tags: ["review", "checklist", "quality"],
     content: %{
       "system_prompt" =>
         "You are a senior code reviewer. For each file, evaluate: 1) Security vulnerabilities 2) Performance concerns 3) Readability issues 4) Maintainability risks. Organize findings by severity: critical, warning, suggestion.",
       "variables" => ["language", "context"]
     }
   }},
  {carol,
   %{
     title: "Architecture Decision Record",
     description:
       "Generates structured ADRs from a problem statement. Includes context, decision drivers, considered options with pros/cons, and the final decision with consequences.",
     type: :prompt,
     visibility: :public,
     tags: ["architecture", "documentation", "adr"],
     content: %{
       "system_prompt" =>
         "Generate an Architecture Decision Record (ADR) in the standard format: Title, Status, Context, Decision Drivers, Considered Options (with pros/cons for each), Decision Outcome, Consequences (positive, negative, neutral).",
       "variables" => ["problem_statement", "constraints"]
     }
   }},
  {alice,
   %{
     title: "Commit Message Writer",
     description:
       "Writes conventional commit messages from diffs. Focuses on the 'why' not the 'what', keeps subjects under 50 chars, uses imperative mood.",
     type: :prompt,
     visibility: :public,
     tags: ["git", "commits", "conventions"],
     content: %{
       "system_prompt" =>
         "Write a conventional commit message for this diff. Subject line: imperative mood, under 50 chars, lowercase. Body: explain WHY the change was made, not what changed (the diff shows that). Use type prefixes: feat, fix, refactor, docs, test, chore.",
       "variables" => ["diff"]
     }
   }},

  # Kin Agents
  {dave,
   %{
     title: "Database Expert",
     description:
       "Coder-role agent specialized in PostgreSQL. Custom system prompt for query optimization, schema design, and migration safety. Includes pganalyze tool override.",
     type: :kin_agent,
     visibility: :public,
     tags: ["postgresql", "database", "optimization"],
     content: %{
       "role" => "coder",
       "system_prompt_extra" =>
         "You specialize in PostgreSQL. Always check query plans with EXPLAIN ANALYZE before approving queries. Prefer CTEs over subqueries for readability. Always add concurrent indexes.",
       "model_override" => nil,
       "tool_overrides" => %{},
       "potency" => 75,
       "spawn_context" =>
         "When the task involves database schema changes, query optimization, or migration work"
     }
   }},
  {carol,
   %{
     title: "Security Auditor",
     description:
       "Reviewer-role agent focused on security analysis. Checks for OWASP top 10, injection vulnerabilities, auth bypasses, and data exposure risks.",
     type: :kin_agent,
     visibility: :public,
     tags: ["security", "audit", "owasp"],
     content: %{
       "role" => "reviewer",
       "system_prompt_extra" =>
         "You are a security-focused reviewer. Check every change for: SQL injection, XSS, CSRF, auth bypass, data exposure, insecure deserialization, and missing rate limiting. Flag severity as critical/high/medium/low.",
       "model_override" => nil,
       "tool_overrides" => %{},
       "potency" => 80,
       "spawn_context" =>
         "When reviewing code that handles user input, authentication, authorization, or external data"
     }
   }},

  # Chat Logs
  {bob,
   %{
     title: "OAuth Refactor Planning Session",
     description:
       "3-agent brainstorm on migrating from session-based auth to OAuth2 + JWT. Covered token rotation, refresh flow, and backward compatibility.",
     type: :chat_log,
     visibility: :public,
     tags: ["oauth", "architecture", "planning"],
     content: %{
       "messages" => [
         %{
           "role" => "user",
           "content" => "We need to migrate from session auth to OAuth2. What's the plan?"
         },
         %{
           "role" => "assistant",
           "content" =>
             "I'd recommend a phased approach: 1) Add OAuth provider alongside sessions, 2) Migrate active users via dual-auth period, 3) Deprecate session-only auth. Key decisions: JWT vs opaque tokens for access, and refresh token rotation strategy."
         },
         %{"role" => "user", "content" => "What about backward compatibility during migration?"},
         %{
           "role" => "assistant",
           "content" =>
             "Run both auth methods simultaneously for 30 days. Session middleware checks for OAuth token first, falls back to session cookie. This gives existing users a seamless transition window."
         }
       ],
       "model" => "anthropic:claude-sonnet-4-20250514",
       "agent_count" => 3,
       "summary" => "Planned phased OAuth2 migration with dual-auth transition period"
     }
   }},
  {alice,
   %{
     title: "Debugging Memory Leak in GenServer",
     description:
       "Walkthrough of finding and fixing a memory leak caused by unbounded ETS table growth in a GenServer that wasn't cleaning up expired entries.",
     type: :chat_log,
     visibility: :public,
     tags: ["debugging", "genserver", "memory", "elixir"],
     content: %{
       "messages" => [
         %{
           "role" => "user",
           "content" =>
             "Our GenServer is eating memory over time. It starts at 50MB and grows to 2GB after a week."
         },
         %{
           "role" => "assistant",
           "content" =>
             "Classic unbounded state growth. Let me check: are you storing anything in ETS or the GenServer state that accumulates? Run `:observer.start()` and check the process info for your GenServer — look at the heap size and message queue."
         },
         %{
           "role" => "user",
           "content" => "Found it — the ETS table has 2M entries. We insert but never delete."
         },
         %{
           "role" => "assistant",
           "content" =>
             "Add a periodic cleanup via `Process.send_after/3` in your `handle_info`. Every 5 minutes, sweep entries older than your TTL using `:ets.select_delete/2` with a match spec on the timestamp field."
         }
       ],
       "model" => "anthropic:claude-sonnet-4-20250514",
       "agent_count" => 2,
       "summary" => "Identified and fixed ETS table memory leak with periodic cleanup"
     }
   }}
]

created_snippets =
  Enum.map(snippets_data, fn {user, attrs} ->
    # Check if snippet already exists for this user
    existing =
      from(s in Loomkin.Schemas.Snippet,
        where: s.user_id == ^user.id and s.title == ^attrs.title
      )
      |> Repo.one()

    if existing do
      existing
    else
      {:ok, snippet} = Social.create_snippet(user, attrs)

      # Backdate some snippets for realistic timestamps
      offset = Enum.random(1..168) * 3600

      from(s in Loomkin.Schemas.Snippet, where: s.id == ^snippet.id)
      |> Repo.update_all(set: [inserted_at: Seeds.ago(offset), updated_at: Seeds.ago(offset)])

      %{snippet | inserted_at: Seeds.ago(offset)}
    end
  end)

IO.puts("✓ Snippets: #{length(created_snippets)} created")

# ── Add some favorites (to populate trending + counts) ────────────────

users = [alice, bob, carol, dave]

for snippet <- created_snippets, snippet.visibility == :public do
  # Each snippet gets 1-4 random favorites
  fans = Enum.take_random(Enum.reject(users, &(&1.id == snippet.user_id)), Enum.random(1..3))

  for fan <- fans do
    unless Social.favorited?(fan, snippet) do
      Social.toggle_favorite(fan, snippet)
    end
  end
end

IO.puts("✓ Favorites: distributed across snippets")

# ── Add follows ──────────────────────────────────────────────────────

follow_pairs = [
  {alice, bob},
  {alice, carol},
  {bob, alice},
  {bob, dave},
  {carol, alice},
  {carol, bob},
  {dave, carol}
]

for {follower, followed} <- follow_pairs do
  unless Social.following?(follower, followed) do
    Social.follow(follower, followed)
  end
end

IO.puts("✓ Follows: #{length(follow_pairs)} relationships")

# ── Fork a couple snippets ───────────────────────────────────────────

debug_detective = Repo.get_by(Loomkin.Schemas.Snippet, title: "Debug Detective")
api_architect = Repo.get_by(Loomkin.Schemas.Snippet, title: "API Design Architect")

if debug_detective do
  existing_fork =
    from(s in Loomkin.Schemas.Snippet,
      where: s.user_id == ^bob.id and s.forked_from_id == ^debug_detective.id
    )
    |> Repo.one()

  unless existing_fork do
    Social.fork_snippet(bob, debug_detective)
    IO.puts("✓ Fork: bob forked debug-detective")
  end
end

if api_architect do
  existing_fork =
    from(s in Loomkin.Schemas.Snippet,
      where: s.user_id == ^dave.id and s.forked_from_id == ^api_architect.id
    )
    |> Repo.one()

  unless existing_fork do
    Social.fork_snippet(dave, api_architect)
    IO.puts("✓ Fork: dave forked api-architect")
  end
end

IO.puts("\n🎉 Seeding complete!\n")
IO.puts("Sample accounts (all use password: password123456):")
IO.puts("  alice@example.com  (alice)")
IO.puts("  bob@example.com    (bob)")
IO.puts("  carol@example.com  (carol)")
IO.puts("  dave@example.com   (dave)")
IO.puts("")
