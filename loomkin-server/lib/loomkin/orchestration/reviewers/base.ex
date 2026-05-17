defmodule Loomkin.Orchestration.Reviewers.Base do
  @moduledoc """
  Shared reviewer scaffolding.

  Concrete reviewers `use` this module:

      defmodule Loomkin.Orchestration.Reviewers.Feasibility do
        use Loomkin.Orchestration.Reviewers.Base,
          name: :feasibility,
          rubric: \"\"\"
          You are the Feasibility reviewer. ...
          \"\"\"
      end

  The macro implements the `Loomkin.Orchestration.Reviewer` behaviour by
  building a chat prompt that includes the rubric and the artifact, asking
  the LLM to respond in a strict JSON shape, then parsing the response into
  a `ReviewVerdict`. Malformed JSON or missing fields are converted into
  a `:fail` verdict with a descriptive blocking message — never silently
  passed.

  The strict JSON contract returned by the LLM:

      {
        "verdict":  "pass" | "fail",
        "evidence": ["path:line", ...],
        "blocking": ["..."],
        "warnings": ["..."],
        "rationale": "..."
      }
  """

  alias Loomkin.Orchestration.LLM
  alias Loomkin.Orchestration.Reviewer
  alias Loomkin.Orchestration.Schema.ReviewVerdict

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    rubric = Keyword.fetch!(opts, :rubric)
    model = Keyword.get(opts, :model)

    quote do
      @behaviour Loomkin.Orchestration.Reviewer

      @impl true
      def name, do: unquote(name)
      @impl true
      def rubric, do: unquote(rubric)
      @impl true
      def model, do: unquote(model)

      @impl true
      def review(payload), do: unquote(__MODULE__).do_review(__MODULE__, payload)

      defoverridable name: 0, rubric: 0, model: 0, review: 1
    end
  end

  @doc false
  def do_review(module, payload) do
    messages = [
      %{role: :system, content: module.rubric()},
      %{role: :user, content: render_payload(payload)}
    ]

    writer_model = Map.get(payload, :writer_model)
    resolved_model = Reviewer.resolve_model(module, writer_model)

    opts =
      [model: resolved_model, reviewer: module.name()]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    with {:ok, text} <- LLM.complete(messages, opts),
         {:ok, parsed} <- parse_json(text) do
      build_verdict(module, parsed, payload, resolved_model)
    else
      {:error, reason} ->
        {:ok,
         fail_verdict(module, "reviewer call failed: #{inspect(reason)}", payload, resolved_model)}

      other ->
        {:ok,
         fail_verdict(
           module,
           "reviewer returned unexpected #{inspect(other)}",
           payload,
           resolved_model
         )}
    end
  end

  defp render_payload(payload) do
    payload
    |> Map.take([
      :epic_id,
      :work_unit_id,
      :iteration,
      :artifact,
      :context,
      :validator_diagnostics
    ])
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == [] end)
    |> Enum.map_join("\n\n", fn
      {k, v} when is_binary(v) -> "## #{k}\n#{v}"
      {k, v} -> "## #{k}\n#{inspect(v, pretty: true, limit: :infinity)}"
    end)
    |> case do
      "" -> "no artifact provided"
      out -> out
    end
  end

  defp parse_json(text) do
    text
    |> String.trim()
    |> strip_code_fences()
    |> Jason.decode()
  end

  defp strip_code_fences(text) do
    cond do
      String.starts_with?(text, "```json") ->
        text
        |> String.replace_prefix("```json", "")
        |> String.trim()
        |> String.replace_suffix("```", "")
        |> String.trim()

      String.starts_with?(text, "```") ->
        text
        |> String.replace_prefix("```", "")
        |> String.trim()
        |> String.replace_suffix("```", "")
        |> String.trim()

      true ->
        text
    end
  end

  defp build_verdict(module, parsed, payload, resolved_model) do
    verdict = parse_verdict(parsed["verdict"])
    evidence = parsed["evidence"] || []
    blocking = parsed["blocking"] || []
    warnings = parsed["warnings"] || []
    rationale = parsed["rationale"] || ""

    {:ok,
     %ReviewVerdict{
       verdict: verdict,
       reviewer: Atom.to_string(module.name()),
       model: resolved_model,
       evidence: Enum.map(evidence, &to_string/1),
       blocking: Enum.map(blocking, &to_string/1),
       warnings: Enum.map(warnings, &to_string/1),
       rationale: to_string(rationale),
       iteration: Map.get(payload, :iteration, 1)
     }}
  end

  defp parse_verdict("pass"), do: :pass
  defp parse_verdict(:pass), do: :pass
  defp parse_verdict("fail"), do: :fail
  defp parse_verdict(:fail), do: :fail
  defp parse_verdict(_), do: :fail

  defp fail_verdict(module, message, payload, resolved_model) do
    %ReviewVerdict{
      verdict: :fail,
      reviewer: Atom.to_string(module.name()),
      model: resolved_model,
      evidence: ["reviewer:#{module.name()}:0"],
      blocking: [message],
      warnings: [],
      rationale: message,
      iteration: Map.get(payload, :iteration, 1)
    }
  end
end
