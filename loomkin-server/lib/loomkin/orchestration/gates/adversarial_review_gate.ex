defmodule Loomkin.Orchestration.Gates.AdversarialReviewGate do
  @moduledoc """
  Per-work-unit DoD verifier. Returns the verdict from `DoDVerifier`,
  but layered with an **evidence enforcement pass**: every verdict — pass
  or fail — must include `file:line` evidence. Verdicts that fail this
  check are rewritten to `:fail` with a synthetic blocking message before
  the aggregate is computed.

  ## Cross-model review

  Callers may include `:writer_model` in the payload. It is threaded
  unchanged through `GateRunner.run/3` to each reviewer, where
  `Loomkin.Orchestration.Reviewer.resolve_model/2` consults
  `:cross_model` / `:reviewer_model_pool` config to pick a model that
  differs from the writer's. No special handling is required here — the
  payload map is passed verbatim to every reviewer task.

  ## Validator diagnostics

  Callers may include `:validator_diagnostics` (a list of `file:line:
  message` strings produced by the in-process validator). These are
  forwarded unchanged to each reviewer's payload and rendered into the
  reviewer's user message by `Loomkin.Orchestration.Reviewers.Base`, so
  the reviewer can cite real validator output instead of hallucinating
  failures. An empty list is omitted from the rendered prompt.
  """
  @behaviour Loomkin.Orchestration.Gate

  alias Loomkin.Orchestration.GateRunner
  alias Loomkin.Orchestration.Reviewers.DoDVerifier
  alias Loomkin.Orchestration.Schema.ReviewVerdict

  @reviewers [DoDVerifier]

  @impl true
  def name, do: :adversarial_review

  @impl true
  def reviewers, do: @reviewers

  @impl true
  def run(payload, opts \\ []) when is_map(payload) do
    {agg, verdicts} = GateRunner.run(@reviewers, payload, opts)

    enforced = Enum.map(verdicts, &enforce_evidence/1)
    aggregate = if Enum.all?(enforced, &(&1.verdict == :pass)), do: :pass, else: :fail
    _ = agg
    {aggregate, enforced}
  end

  defp enforce_evidence(%ReviewVerdict{} = v) do
    case ReviewVerdict.validate_evidence(v.evidence) do
      :ok ->
        v

      {:error, problems} ->
        %ReviewVerdict{
          v
          | verdict: :fail,
            blocking:
              v.blocking ++
                ["adversarial-review-gate rejected verdict: #{Enum.join(problems, "; ")}"]
        }
    end
  end
end
