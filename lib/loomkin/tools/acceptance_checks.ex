defmodule Loomkin.Tools.AcceptanceChecks do
  @moduledoc """
  Tool for running acceptance criteria checks on completed task work products.

  Used by the UpstreamVerifier to validate that upstream work meets quality
  standards before dependent tasks proceed.
  """

  use Jido.Action,
    name: "acceptance_checks",
    description: """
    Run acceptance checks on a task's work product. Supports check types:
    syntax (compile check), tests (run test suite), lint (code formatting),
    and spec (verify task requirements are met). Returns structured pass/fail
    results with details.
    """,
    schema: [
      check_type: [
        type: {:in, [:syntax, :tests, :lint, :spec]},
        required: true,
        doc: "Type of acceptance check to run"
      ],
      task_id: [type: :string, required: true, doc: "ID of the task to verify"],
      files_changed: [
        type: {:list, :string},
        doc: "List of files changed by the task (optional, narrows scope)"
      ],
      spec_description: [
        type: :string,
        doc: "Task spec/requirements to verify against (for :spec check type)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  @syntax_timeout 60_000
  @test_timeout 120_000
  @lint_timeout 30_000

  @impl true
  def run(params, context) do
    check_type = param!(params, :check_type)
    project_path = param!(context, :project_path)

    case check_type do
      :syntax -> run_syntax_check(project_path)
      :tests -> run_test_check(project_path, params)
      :lint -> run_lint_check(project_path)
      :spec -> run_spec_check(params)
    end
  end

  defp run_syntax_check(project_path) do
    case execute_command("mix compile --warnings-as-errors 2>&1", project_path, @syntax_timeout) do
      {:ok, output, 0} ->
        {:ok,
         %{
           result: "PASSED: Compilation successful.\n#{truncate(output)}",
           check_type: :syntax,
           passed: true
         }}

      {:ok, output, _code} ->
        {:ok,
         %{
           result: "FAILED: Compilation errors detected.\n#{truncate(output)}",
           check_type: :syntax,
           passed: false
         }}

      {:error, reason} ->
        {:ok,
         %{
           result: "ERROR: Syntax check failed to run: #{reason}",
           check_type: :syntax,
           passed: false
         }}
    end
  end

  defp run_test_check(project_path, params) do
    files_changed = param(params, :files_changed, [])

    command =
      if files_changed != [] do
        # Run only tests related to changed files
        test_files =
          files_changed
          |> Enum.map(&source_to_test_path/1)
          |> Enum.filter(&File.exists?(Path.join(project_path, &1)))
          |> Enum.join(" ")

        if test_files == "" do
          "mix test --max-failures 5 2>&1"
        else
          "mix test #{test_files} --max-failures 5 2>&1"
        end
      else
        "mix test --max-failures 5 2>&1"
      end

    case execute_command(command, project_path, @test_timeout) do
      {:ok, output, 0} ->
        {:ok,
         %{
           result: "PASSED: All tests pass.\n#{truncate(output)}",
           check_type: :tests,
           passed: true
         }}

      {:ok, output, _code} ->
        {:ok,
         %{
           result: "FAILED: Test failures detected.\n#{truncate(output)}",
           check_type: :tests,
           passed: false
         }}

      {:error, reason} ->
        {:ok,
         %{
           result: "ERROR: Test check failed to run: #{reason}",
           check_type: :tests,
           passed: false
         }}
    end
  end

  defp run_lint_check(project_path) do
    case execute_command("mix format --check-formatted 2>&1", project_path, @lint_timeout) do
      {:ok, _output, 0} ->
        {:ok,
         %{
           result: "PASSED: All files properly formatted.",
           check_type: :lint,
           passed: true
         }}

      {:ok, output, _code} ->
        {:ok,
         %{
           result: "FAILED: Formatting issues detected.\n#{truncate(output)}",
           check_type: :lint,
           passed: false
         }}

      {:error, reason} ->
        {:ok,
         %{
           result: "ERROR: Lint check failed to run: #{reason}",
           check_type: :lint,
           passed: false
         }}
    end
  end

  defp run_spec_check(params) do
    spec = param(params, :spec_description, nil)
    task_id = param!(params, :task_id)

    if is_nil(spec) or spec == "" do
      {:ok,
       %{
         result: "SKIPPED: No spec description provided for task #{task_id}.",
         check_type: :spec,
         passed: true
       }}
    else
      # Spec checks are evaluated by the LLM agent using the spec description
      # as context. Return the spec for the agent to evaluate.
      {:ok,
       %{
         result:
           "MANUAL: Review the following spec against the task output:\n#{spec}\n\nEvaluate whether the task output satisfies these requirements.",
         check_type: :spec,
         passed: :pending
       }}
    end
  end

  defp execute_command(command, project_path, timeout) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        {:args, ["-c", command]},
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, project_path}
      ])

    collect_output(port, [], timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | acc], timeout)

      {^port, {:exit_status, code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, output, code}
    after
      timeout ->
        Port.close(port)
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp truncate(output) do
    if byte_size(output) > 5000 do
      String.slice(output, 0, 5000) <> "\n... (truncated)"
    else
      output
    end
  end

  defp source_to_test_path(path) do
    path
    |> String.replace("lib/", "test/")
    |> String.replace(".ex", "_test.exs")
  end
end
