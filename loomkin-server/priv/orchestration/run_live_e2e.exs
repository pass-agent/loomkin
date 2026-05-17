# Live end-to-end orchestration smoke runner.
#
# Submits a real epic against the configured ReqLLM provider. Gated behind
# LOOMKIN_ORCHESTRATION_LIVE_E2E=1 so it never runs in CI without intent.
#
#   LOOMKIN_ORCHESTRATION_LIVE_E2E=1 \
#     mix run priv/orchestration/run_live_e2e.exs
#
# Notes:
#   - This script intentionally uses the real LLM adapter. Expect API spend.
#   - The epic is created in the DB; the trace is appended to
#     docs/orchestration/E2E_TRACE.md (in the *parent* repo) so future
#     readers see what success looks like.
#   - The fixture project at priv/orchestration/fixtures/sample_repo is
#     copied to a temp dir, git-initialised, and used as the worktree base.

unless System.get_env("LOOMKIN_ORCHESTRATION_LIVE_E2E") == "1" do
  IO.puts(:stderr, """
  Refusing to run: set LOOMKIN_ORCHESTRATION_LIVE_E2E=1 to confirm you want
  to spend real LLM tokens on this smoke test.
  """)

  System.halt(2)
end

alias Loomkin.Orchestration
alias Loomkin.Orchestration.{Callbacks, IssueOrchestrator, LLM}
alias Loomkin.Orchestration.Schema.Epic

# ─── 1. Force the real LLM adapter ──────────────────────────────────────────
#
# LOOMKIN_DEFAULT_MODEL overrides the configured default model just for this
# run. Useful for picking a Google-OAuth-backed Gemini model
# (`google_oauth:gemini-2.5-flash`) without editing config — the
# Loomkin.Providers.GoogleOAuth provider reads the bearer token from
# Loomkin.Auth.TokenStore, populated by the in-app /auth/google flow.

orch_overrides =
  [llm_adapter: Loomkin.Orchestration.LLM.ReqLLM]
  |> then(fn opts ->
    case System.get_env("LOOMKIN_DEFAULT_MODEL") do
      nil -> opts
      "" -> opts
      model -> Keyword.put(opts, :default_model, model)
    end
  end)

Application.put_env(
  :loomkin,
  Loomkin.Orchestration,
  Keyword.merge(
    Application.get_env(:loomkin, Loomkin.Orchestration, []),
    orch_overrides
  )
)

orch_env = Application.get_env(:loomkin, Loomkin.Orchestration, [])
provider_model = Keyword.get(orch_env, :default_model, "unknown")
provider_adapter = Keyword.get(orch_env, :llm_adapter, "unknown") |> inspect()

IO.puts("provider adapter: #{provider_adapter}")
IO.puts("provider model:   #{provider_model}")

# ─── 2. Provider preflight ──────────────────────────────────────────────────
#
# Before we charge for an entire orchestration run, do a tiny probe. If the
# adapter blows up here, halt with code 3 so the caller knows it's a config
# problem, not an orchestration bug.

preflight =
  try do
    LLM.complete(
      [
        %{role: :system, content: "ping"},
        %{role: :user, content: "say ok"}
      ],
      reviewer: :preflight,
      timeout: 5_000
    )
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

case preflight do
  {:ok, _} ->
    IO.puts("preflight ok")

  {:error, reason} ->
    IO.puts(:stderr, """
    Provider preflight failed: #{inspect(reason)}

    Check that the configured provider has credentials in the environment
    (e.g. ANTHROPIC_API_KEY, OPENAI_API_KEY, OLLAMA_HOST) and that
    :default_model / :llm_adapter are set in config.
    """)

    System.halt(3)
end

# ─── 3. Worktree wiring ─────────────────────────────────────────────────────
#
# Copy the fixture repo into a temp dir, git-init it, commit the baseline so
# `git worktree add` has a HEAD to branch from.

fixture_src =
  Path.expand("fixtures/sample_repo", __DIR__)

unless File.dir?(fixture_src) do
  IO.puts(:stderr, "Fixture repo missing at #{fixture_src}")
  System.halt(4)
end

repo_root =
  Path.join(System.tmp_dir!(), "loomkin-live-e2e-#{System.unique_integer([:positive])}")

File.mkdir_p!(repo_root)
File.cp_r!(fixture_src, repo_root)

{_, 0} = System.cmd("git", ["-C", repo_root, "init", "--initial-branch=main"])
{_, 0} = System.cmd("git", ["-C", repo_root, "add", "."])

{_, 0} =
  System.cmd("git", [
    "-C",
    repo_root,
    "-c",
    "user.email=live-e2e@loomkin.local",
    "-c",
    "user.name=loomkin-live-e2e",
    "commit",
    "-m",
    "baseline fixture"
  ])

IO.puts("fixture worktree base: #{repo_root}")

# ─── 4. Create the epic row ─────────────────────────────────────────────────

epic_id = Ecto.UUID.generate()
title = "live e2e — " <> DateTime.to_iso8601(DateTime.utc_now())

{:ok, epic_row} =
  Loomkin.Repo.insert(
    Epic.changeset(%Epic{}, %{
      id: epic_id,
      title: title,
      spec: """
      ## Goal
      The fixture project at the supplied worktree contains a `Greeter`
      module whose `greet/1` function ignores its argument and always
      returns `"hello, anonymous"`. Fix the bug so
      `Greeter.greet("vincent") == "hello, vincent"` and `mix test` passes
      inside the worktree.

      ## Out of scope
      Adding new functions, refactoring the module, or touching unrelated
      files.
      """,
      dod_items: [
        %{id: "1", text: "Greeter.greet/1 returns \"hello, <name>\"", verifier: :test},
        %{id: "2", text: "module compiles cleanly", verifier: :build}
      ],
      worktree_path: repo_root,
      base_branch: "main"
    })
  )

IO.puts("created epic #{epic_row.id}")

epic = %{
  id: epic_row.id,
  title: epic_row.title,
  spec: epic_row.spec,
  worktree_path: repo_root,
  base_branch: "main"
}

callbacks = Callbacks.default_issue_callbacks()

Phoenix.PubSub.subscribe(Loomkin.PubSub, "orchestration.epic")
Phoenix.PubSub.subscribe(Loomkin.PubSub, "orchestration.work_unit")

{:ok, pid} =
  IssueOrchestrator.start_link(epic: epic, callbacks: callbacks, owner: self())

IssueOrchestrator.start(pid)

defmodule LiveTrace do
  def loop(events) do
    receive do
      {"orchestration.epic", %{event: ev}} ->
        IO.inspect({:epic, ev}, label: "live")
        loop([{:epic, ev} | events])

      {"orchestration.work_unit", %{event: ev, work_unit_id: id}} ->
        IO.inspect({:wu, id, ev}, label: "live")
        loop([{:wu, id, ev} | events])

      {:issue_orchestrator, _pid, terminal_state} ->
        Enum.reverse([{:terminal, terminal_state} | events])
    after
      :timer.minutes(15) ->
        Enum.reverse([{:timeout, :no_terminal_state} | events])
    end
  end
end

trace = LiveTrace.loop([])

# ─── 5. Write the trace to the *parent* repo's docs ─────────────────────────

trace_path = Path.expand("../docs/orchestration/E2E_TRACE.md", File.cwd!())
File.mkdir_p!(Path.dirname(trace_path))

File.write!(
  trace_path,
  """
  # Live orchestration E2E trace

  Captured at:      #{DateTime.to_iso8601(DateTime.utc_now())}
  Epic id:          #{epic_id}
  Provider adapter: #{provider_adapter}
  Provider model:   #{provider_model}
  Worktree base:    #{repo_root}

  ## Trace

  ```
  #{inspect(trace, pretty: true, limit: :infinity)}
  ```

  ## Phases reached

  #{Orchestration.phases() |> Enum.map_join("\n", &("- " <> Atom.to_string(&1)))}
  """
)

IO.puts("trace written to #{trace_path}")
IO.puts("done.")
