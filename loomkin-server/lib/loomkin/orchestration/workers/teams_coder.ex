defmodule Loomkin.Orchestration.Workers.TeamsCoder do
  @moduledoc """
  Real `WorkUnitPipeline.implementer` backed by `Loomkin.Teams.Agent`.

  Replaces the stub `Loomkin.Orchestration.Workers.Coder` for any pipeline
  configured with `implementer: &TeamsCoder.implement/1`.

  Flow:

    1. Spawn (or reuse) a coder-role agent under the epic's team via
       `Loomkin.Teams.Manager.spawn_agent/4`.
    2. Render the work-unit context into a single user message.
    3. Send it via `Loomkin.Teams.Agent.send_message/2` (synchronous,
       infinity timeout).
    4. Capture the agent's response as the artifact.
    5. Best-effort stop the agent (next-iteration concern: pool & reuse).

  This is intentionally a thin wrapper. Real-world tuning — pooling agents,
  attaching to existing team contexts, capturing diffs from the agent's tool
  calls — is layered on top in follow-up work units.

  Returned artifact:

      %{
        "files_touched" => [...],
        "notes" => agent_response_text,
        "agent_pid" => pid()
      }

  `files_touched` is heuristically extracted from the response (any
  file-path-shaped token). The committer accepts an empty list and falls
  back to `git add -A`.
  """

  alias Loomkin.Orchestration.Knowledge.Primer
  alias Loomkin.Orchestration.Workers.Base
  alias Loomkin.Teams.{Agent, Manager}

  @file_regex ~r{[a-zA-Z0-9_./-]+\.(?:ex|exs|heex|ts|tsx|js|jsx|md|json|yml|yaml|sql|sh)}

  @doc """
  Implementer callback for `WorkUnitPipeline`. Accepts the rich payload map
  the pipeline threads through — `%{work_unit, prior_failures, ...}` — plus
  optional keyword opts (used by callers that bypass the pipeline). Returns
  `{:ok, artifact}` or `{:error, reason}`.
  """
  @spec implement(map(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def implement(work_unit, payload_or_opts \\ %{})

  def implement(work_unit, payload) when is_map(work_unit) and is_map(payload) do
    opts =
      []
      |> maybe_put_keyword(:prime_keywords, Map.get(payload, :prime_keywords))

    do_implement(work_unit, Map.get(payload, :prior_failures, []), opts)
  end

  def implement(work_unit, opts) when is_map(work_unit) and is_list(opts) do
    do_implement(work_unit, Keyword.get(opts, :prior_failures, []), opts)
  end

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, _key, []), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp do_implement(work_unit, prior_failures, opts) do
    team_id = Keyword.get(opts, :team_id) || work_unit[:team_id] || work_unit["team_id"]
    project_path = Keyword.get(opts, :project_path) || work_unit[:project_path]
    prime_keywords = Keyword.get(opts, :prime_keywords)

    case team_id do
      nil ->
        {:error, :missing_team_id}

      tid ->
        agent_name =
          "coder-" <> Elixir.Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)

        spawn_opts =
          [
            project_path: project_path,
            model: Keyword.get(opts, :model)
          ]
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        case Manager.spawn_agent(tid, agent_name, :coder, spawn_opts) do
          {:ok, pid} ->
            try do
              prompt =
                work_unit
                |> render_prompt(prior_failures)
                |> prepend_primed_section(prime_keywords)

              response = Agent.send_message(pid, prompt)
              artifact = artifact_from(response)
              {:ok, artifact}
            catch
              kind, reason -> {:error, {:agent_failure, kind, reason}}
            after
              try do
                Manager.stop_agent(tid, agent_name)
              rescue
                _ -> :ok
              catch
                _, _ -> :ok
              end
            end

          {:error, reason} ->
            {:error, {:spawn_failed, reason}}
        end
    end
  end

  @doc """
  Renders the work-unit prompt the agent receives. Exposed for tests so they
  can assert that prior-failure context is included on retry attempts.
  """
  @spec render_prompt(map(), [map()]) :: String.t()
  def render_prompt(work_unit, prior_failures \\ []) do
    title = work_unit[:title] || work_unit["title"] || "untitled"
    description = work_unit[:description] || work_unit["description"] || ""
    file_scope = work_unit[:file_scope] || work_unit["file_scope"] || []
    dod = work_unit[:dod_items] || work_unit["dod_items"] || []

    prior_section = render_prior_failures(prior_failures)

    body = """
    # Work unit: #{title}

    ## Description
    #{description}

    ## File scope
    #{Enum.map_join(file_scope, "\n", &("- " <> &1))}

    ## Definition of Done
    #{Enum.map_join(dod, "\n", fn item ->
      id = Map.get(item, :id) || Map.get(item, "id") || "?"
      text = Map.get(item, :text) || Map.get(item, "text") || ""
      "- [#{id}] #{text}"
    end)}

    Make the changes inside the worktree. Use the file tools to apply edits.
    When done, summarize what you changed and which files were touched.
    """

    case prior_section do
      nil -> body
      section -> section <> "\n\n" <> body
    end
  end

  # Prepends a "## Primed knowledge" section to the prompt whenever the caller
  # supplied `prime_keywords`. Mirrors `Workers.Base.do_call/4`'s priming so
  # the agent sees the top-N relevant facts before everything else.
  defp prepend_primed_section(prompt, nil), do: prompt
  defp prepend_primed_section(prompt, []), do: prompt

  defp prepend_primed_section(prompt, keywords) when is_list(keywords) do
    facts =
      try do
        Primer.prime(keywords: keywords, limit: 5)
      rescue
        _ -> []
      catch
        :exit, _ -> []
        :throw, _ -> []
        _, _ -> []
      end

    case facts do
      [] -> prompt
      _ -> Base.render_primed_facts(facts) <> "\n\n" <> prompt
    end
  end

  # Prepends a "## Prior attempts" section to the prompt whenever earlier
  # iterations failed the adversarial review (or validator). Each verdict's
  # blocking items + evidence appear so the agent does not repeat the same
  # mistake.
  defp render_prior_failures(nil), do: nil
  defp render_prior_failures([]), do: nil

  defp render_prior_failures(failures) when is_list(failures) do
    rendered =
      failures
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {failure, idx} ->
        iteration = Map.get(failure, :iteration) || Map.get(failure, "iteration") || idx
        verdicts = Map.get(failure, :verdicts) || Map.get(failure, "verdicts") || []

        "### Attempt #{iteration}\n" <> render_verdicts(verdicts)
      end)

    "## Prior attempts (DO NOT repeat these failures)\n\n" <> rendered
  end

  defp render_verdicts([]), do: "_(no verdicts recorded)_"

  defp render_verdicts(verdicts) when is_list(verdicts) do
    Enum.map_join(verdicts, "\n\n", &render_verdict/1)
  end

  defp render_verdict(verdict) do
    reviewer = Map.get(verdict, :reviewer) || Map.get(verdict, "reviewer") || "reviewer"
    blocking = Map.get(verdict, :blocking) || Map.get(verdict, "blocking") || []
    evidence = Map.get(verdict, :evidence) || Map.get(verdict, "evidence") || []

    blocking_lines =
      if blocking == [], do: "- (none)", else: Enum.map_join(blocking, "\n", &("- " <> &1))

    evidence_lines =
      if evidence == [], do: "- (none)", else: Enum.map_join(evidence, "\n", &("- " <> &1))

    "**#{reviewer}**\n\nBlocking:\n#{blocking_lines}\n\nEvidence:\n#{evidence_lines}"
  end

  defp artifact_from(response) when is_binary(response) do
    files =
      @file_regex
      |> Regex.scan(response)
      |> List.flatten()
      |> Enum.uniq()

    %{
      "files_touched" => files,
      "notes" => response
    }
  end

  defp artifact_from(other) do
    %{"files_touched" => [], "notes" => inspect(other)}
  end
end
