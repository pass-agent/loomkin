defmodule Loomkin.Tools.FixConfirmation do
  @moduledoc "Tool for fixer agents to confirm repair and report changes."

  use Jido.Action,
    name: "fix_confirmation",
    description: """
    Confirm that a fix has been applied and verified.
    This is the final action of a fixer agent.
    """,
    schema: [
      session_id: [type: :string, required: true, doc: "The healing session ID"],
      description: [
        type: :string,
        required: true,
        doc: "What was changed and why"
      ],
      files_changed: [
        type: {:list, :string},
        required: true,
        doc: "List of modified file paths"
      ],
      verified: [
        type: :boolean,
        required: true,
        doc: "Whether the fix was verified (e.g., tests pass, no diagnostics)"
      ],
      verification_output: [
        type: :string,
        doc: "Output from verification step (test results, diagnostic check)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  @orchestrator Loomkin.Healing.Orchestrator

  @impl true
  def run(params, _context) do
    session_id = param!(params, :session_id)
    verified = param!(params, :verified)

    if verified do
      fix_result = %{
        description: param!(params, :description),
        files_changed: param!(params, :files_changed),
        verification_output: param(params, :verification_output)
      }

      call_orchestrator(:confirm_fix, [session_id, fix_result],
        ok: "Fix confirmed. Original agent will be woken up.",
        error_prefix: "Failed to confirm fix"
      )
    else
      description = param!(params, :description)

      call_orchestrator(:fix_failed, [session_id, description],
        ok: "Fix not verified. Orchestrator will decide whether to retry.",
        error_prefix: "Failed to report fix failure"
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
