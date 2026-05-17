defmodule Loomkin.Orchestration.GateRunner do
  @moduledoc """
  Shared helper that fans reviewers out under a `Task.Supervisor` and
  aggregates their verdicts.

  Concrete gates (`PlanReviewGate`, `DesignReviewGate`, `AdversarialReviewGate`)
  delegate the fan-out mechanics here so the parallelism/timeout/error policy
  lives in one place.
  """

  alias Loomkin.Orchestration.Reviewer
  alias Loomkin.Orchestration.Schema.ReviewVerdict

  @task_supervisor Loomkin.Orchestration.ReviewGate.Supervisor

  @default_timeout :timer.seconds(90)

  @doc """
  Runs every reviewer in parallel against `payload`. Returns the aggregate
  verdict and the list of individual verdicts.

  Options:

    * `:timeout` — per-reviewer deadline (ms). Default 90s.
    * `:task_supervisor` — override the default `Task.Supervisor` name.
  """
  @spec run([module()], Reviewer.payload(), Keyword.t()) ::
          {:pass | :fail, [ReviewVerdict.t()]}
  def run(reviewers, payload, opts \\ []) when is_list(reviewers) and is_map(payload) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    sup = Keyword.get(opts, :task_supervisor, @task_supervisor)

    verdicts =
      sup
      |> Task.Supervisor.async_stream_nolink(
        reviewers,
        fn module -> safe_review(module, payload) end,
        max_concurrency: max(length(reviewers), 1),
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(reviewers)
      |> Enum.map(&normalize_result/1)

    aggregate =
      if Enum.all?(verdicts, &(&1.verdict == :pass)), do: :pass, else: :fail

    {aggregate, verdicts}
  end

  defp safe_review(module, payload) do
    module.review(payload)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp normalize_result({{:ok, {:ok, %ReviewVerdict{} = v}}, _module}) do
    v
  end

  defp normalize_result({{:ok, {:error, reason}}, module}) do
    fail_verdict(module, "reviewer error: #{inspect(reason)}")
  end

  defp normalize_result({{:exit, reason}, module}) do
    fail_verdict(module, "reviewer crashed: #{inspect(reason)}")
  end

  defp normalize_result({{:ok, other}, module}) do
    fail_verdict(module, "reviewer returned unexpected value: #{inspect(other)}")
  end

  defp fail_verdict(module, message) do
    %ReviewVerdict{
      verdict: :fail,
      reviewer: inspect(module),
      evidence: [],
      blocking: [message],
      warnings: [],
      rationale: message
    }
  end
end
