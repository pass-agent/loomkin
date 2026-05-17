defmodule Loomkin.Orchestration.Callbacks do
  @moduledoc """
  Factory for the callbacks maps that `IssueOrchestrator` and
  `WorkUnitPipeline` expect.

  Use `default_issue_callbacks/1` to wire the standard workers + gates.
  Tests can override individual entries.
  """

  alias Loomkin.Orchestration.{Curator, Executor, Workers}
  alias Loomkin.Orchestration.Gates.{AdversarialReviewGate, DesignReviewGate, PlanReviewGate}

  @doc """
  Returns the canonical callbacks map for an epic, with optional overrides.

      Callbacks.default_issue_callbacks()
      Callbacks.default_issue_callbacks(plan_review: &MyStub.plan_review/1)
  """
  @spec default_issue_callbacks(map()) :: map()
  def default_issue_callbacks(overrides \\ %{}) when is_map(overrides) do
    Map.merge(
      %{
        researcher: fn epic ->
          Workers.Researcher.call(%{epic: epic}, prime_keywords: keywords_from_epic(epic))
        end,
        planner: fn epic, research ->
          Workers.Planner.call(%{epic: epic, research: research},
            prime_keywords: keywords_from_epic(epic)
          )
        end,
        plan_review: fn plan ->
          PlanReviewGate.run(%{artifact: plan})
        end,
        design_review: fn plan ->
          DesignReviewGate.run(%{artifact: plan})
        end,
        decomposer: fn plan ->
          case plan do
            %{"work_units" => wus} when is_list(wus) ->
              {:ok, Enum.map(wus, &normalize_wu/1)}

            %{work_units: wus} when is_list(wus) ->
              {:ok, Enum.map(wus, &normalize_wu/1)}

            _ ->
              {:error, :no_work_units}
          end
        end,
        executor: fn epic, work_units ->
          Executor.run(epic, work_units,
            worktree_path: epic_worktree_path(epic),
            callbacks: default_work_unit_callbacks()
          )
        end,
        final_review: fn _epic, results ->
          AdversarialReviewGate.run(%{artifact: %{final: true, results: results}})
        end,
        pr_opener: fn _epic, _results ->
          {:ok, "https://example.com/pr/local-#{System.unique_integer([:positive])}"}
        end,
        knowledge: fn epic, results ->
          case Curator.extract(%{
                 epic_id: Map.get(epic, :id),
                 work_unit_id: nil,
                 results: results
               }) do
            {:ok, facts} -> {:ok, facts}
            other -> other
          end
        end
      },
      overrides
    )
  end

  @doc "Default work-unit pipeline callbacks (used by Executor)."
  @spec default_work_unit_callbacks() :: map()
  def default_work_unit_callbacks do
    %{
      implementer: &implement/2,
      validator: &validate/2,
      reviewer: &review/2,
      committer: &commit/2
    }
  end

  # ─── Default per-step callbacks ─────────────────────────────────────────────
  #
  # All four callbacks share the new arity-2 signature: `(primary_arg, payload)`
  # where `primary_arg` is the bare work_unit for the implementer and the
  # artifact for the rest. `payload` is the rich map the pipeline now threads
  # through — `%{work_unit, artifact, prior_failures, attempt_knobs, iteration}` —
  # so callbacks can act on prior failure verdicts when re-implementing.

  defp implement(work_unit, payload) do
    prior_failures = Map.get(payload, :prior_failures, [])
    prime_keywords = keywords_from_work_unit(work_unit)

    case Workers.Coder.call(%{work_unit: work_unit, prior_failures: prior_failures},
           prime_keywords: prime_keywords
         ) do
      {:ok, artifact} when is_map(artifact) ->
        {:ok, maybe_propagate_worktree(artifact, work_unit)}

      other ->
        other
    end
  end

  defp maybe_propagate_worktree(artifact, %{worktree_path: path}) when is_binary(path) do
    Map.put_new(artifact, :worktree_path, path)
  end

  defp maybe_propagate_worktree(artifact, _), do: artifact

  # Trust-nothing: validator runs by orchestrator (in-process). Default checks
  # the artifact has the expected shape; concrete projects swap in real
  # validators (mix test / mix format / etc.). Validator doesn't need
  # prior_failures but accepts the richer shape for consistency.
  defp validate(artifact, _payload) do
    cond do
      not is_map(artifact) ->
        {:error, ["artifact is not a map"]}

      not Map.has_key?(artifact, "files_touched") and
          not Map.has_key?(artifact, :files_touched) ->
        {:error, ["artifact missing files_touched"]}

      true ->
        :ok
    end
  end

  defp review(artifact, payload) do
    diagnostics = Map.get(payload, :validator_diagnostics, [])
    AdversarialReviewGate.run(%{artifact: artifact, validator_diagnostics: diagnostics})
  end

  defp commit(artifact, _payload) do
    case worktree_path(artifact) do
      path when is_binary(path) ->
        commit_in_worktree(artifact, path)

      _ ->
        rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
        {:ok, "sha-#{rand}-#{short_artifact_hash(artifact)}"}
    end
  end

  defp worktree_path(%{worktree_path: path}) when is_binary(path), do: path
  defp worktree_path(%{"worktree_path" => path}) when is_binary(path), do: path
  defp worktree_path(_), do: nil

  # Stage everything in the worktree dir and commit. Returns the commit SHA on
  # success. Failures bubble up as `{:error, reason}` so the pipeline can react.
  defp commit_in_worktree(artifact, worktree_path) do
    message =
      Map.get(artifact, :commit_message) || Map.get(artifact, "commit_message") ||
        "loomkin: work unit commit"

    with {_, 0} <-
           System.cmd("git", ["-C", worktree_path, "add", "-A"], stderr_to_stdout: true),
         {_, 0} <-
           System.cmd(
             "git",
             [
               "-C",
               worktree_path,
               "commit",
               "--allow-empty",
               "-m",
               message
             ],
             stderr_to_stdout: true
           ),
         {sha, 0} <-
           System.cmd("git", ["-C", worktree_path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {:ok, String.trim(sha)}
    else
      {out, code} -> {:error, {:git_commit_failed, code, out}}
    end
  end

  defp short_artifact_hash(artifact) do
    artifact
    |> inspect()
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  # The executor passes `epic` as either a plain map or an IssueOrchestrator data
  # struct snapshot. Look at known shapes: `:artifacts[:worktree_path]` (set by
  # IssueOrchestrator on :research enter), then `epic.metadata.worktree_path`,
  # otherwise nil — the executor will skip injecting the key.
  defp epic_worktree_path(epic) when is_map(epic) do
    case epic do
      %{artifacts: %{worktree_path: path}} when is_binary(path) -> path
      %{"artifacts" => %{"worktree_path" => path}} when is_binary(path) -> path
      %{metadata: %{worktree_path: path}} when is_binary(path) -> path
      %{metadata: %{"worktree_path" => path}} when is_binary(path) -> path
      %{"metadata" => %{"worktree_path" => path}} when is_binary(path) -> path
      _ -> nil
    end
  end

  defp epic_worktree_path(_), do: nil

  # Tiny stopword list — we deliberately stay coarse so the keyword extractor
  # remains deterministic and trivially testable. Anything longer than 3 chars
  # (and not in the stoplist) is treated as a candidate keyword.
  @stopwords MapSet.new(~w(
    the and for with from this that into onto over when what where which while
    your they them their make made build builds support supports add adds
    update updates remove removes feat fix chore docs test tests
  ))

  @doc """
  Derives prime keywords from an epic. Splits the title on non-word chars,
  drops short tokens and stopwords, and lower-cases the rest.
  """
  @spec keywords_from_epic(map()) :: [String.t()]
  def keywords_from_epic(epic) when is_map(epic) do
    title = Map.get(epic, :title) || Map.get(epic, "title") || ""
    tokens_from(title)
  end

  def keywords_from_epic(_), do: []

  @doc """
  Derives prime keywords from a work unit. Combines the title's significant
  tokens with any explicit `:tags`.
  """
  @spec keywords_from_work_unit(map()) :: [String.t()]
  def keywords_from_work_unit(wu) when is_map(wu) do
    title = Map.get(wu, :title) || Map.get(wu, "title") || ""
    tags = Map.get(wu, :tags) || Map.get(wu, "tags") || []

    tokens_from(title)
    |> Kernel.++(Enum.map(tags, &to_string/1))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  def keywords_from_work_unit(_), do: []

  defp tokens_from(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.filter(fn t -> String.length(t) > 3 and not MapSet.member?(@stopwords, t) end)
    |> Enum.uniq()
  end

  defp tokens_from(_), do: []

  defp normalize_wu(wu) when is_map(wu) do
    %{
      id: wu["id"] || wu[:id] || Ecto.UUID.generate(),
      title: wu["title"] || wu[:title] || "untitled",
      description: wu["description"] || wu[:description],
      file_scope: wu["file_scope"] || wu[:file_scope] || [],
      deps: wu["deps"] || wu[:deps] || [],
      dod_items: wu["dod_items"] || wu[:dod_items] || []
    }
  end
end
