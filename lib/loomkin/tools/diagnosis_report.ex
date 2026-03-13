defmodule Loomkin.Tools.DiagnosisReport do
  @moduledoc "Tool for diagnostician agents to submit structured diagnosis findings."

  use Jido.Action,
    name: "diagnosis_report",
    description: """
    Submit a structured diagnosis report identifying the root cause of an error.
    This is the final action of a diagnostician agent.
    """,
    schema: [
      session_id: [type: :string, required: true, doc: "The healing session ID"],
      root_cause: [
        type: :string,
        required: true,
        doc: "Clear description of the root cause"
      ],
      affected_files: [
        type: {:list, :string},
        required: true,
        doc: "List of file paths involved"
      ],
      suggested_fix: [
        type: :string,
        required: true,
        doc: "Specific fix instructions for the fixer agent"
      ],
      severity: [
        type: {:in, [:low, :medium, :high, :critical]},
        required: true,
        doc: "Assessed severity of the issue"
      ],
      confidence: [
        type: :float,
        required: true,
        doc: "Confidence in diagnosis (0.0 to 1.0)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2]

  @orchestrator Loomkin.Healing.Orchestrator

  @impl true
  def run(params, _context) do
    session_id = param!(params, :session_id)
    confidence = param!(params, :confidence)

    if confidence < 0.0 or confidence > 1.0 do
      {:error, "confidence must be between 0.0 and 1.0, got: #{confidence}"}
    else
      diagnosis = %{
        root_cause: param!(params, :root_cause),
        affected_files: param!(params, :affected_files),
        suggested_fix: param!(params, :suggested_fix),
        severity: param!(params, :severity),
        confidence: confidence
      }

      call_orchestrator(:report_diagnosis, [session_id, diagnosis],
        ok: "Diagnosis submitted. Fixer agent will be spawned to apply the fix.",
        error_prefix: "Failed to submit diagnosis"
      )
    end
  end

  defp call_orchestrator(func, args, opts) do
    if Code.ensure_loaded?(@orchestrator) && function_exported?(@orchestrator, func, length(args)) do
      case apply(@orchestrator, func, args) do
        :ok ->
          {:ok, %{result: opts[:ok]}}

        {:error, reason} ->
          {:error, "#{opts[:error_prefix]}: #{inspect(reason)}"}
      end
    else
      {:error, "Healing orchestrator is not available"}
    end
  end
end
