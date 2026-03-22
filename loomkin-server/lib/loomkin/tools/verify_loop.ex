defmodule Loomkin.Tools.VerifyLoop do
  @moduledoc """
  Tool for agents to spawn autonomous verification loops.

  Spawns a `Loomkin.Verification.Loop` GenServer under the
  verification supervisor. Returns the loop_id for status queries.
  """

  use Jido.Action,
    name: "verify_loop",
    description: """
    Spawn an autonomous verification loop that runs test → diagnose → fix → re-test
    cycles. Returns a loop_id you can use to check status. The loop runs independently
    and checkpoints progress to the workspace.

    Use this when you need to iterate on getting tests to pass without manual
    intervention. The loop will stop when tests pass, max iterations reached,
    or timeout expires.
    """,
    schema: [
      test_command: [
        type: :string,
        required: true,
        doc: "Shell command to run tests (e.g. 'mix test test/my_test.exs')"
      ],
      success_criteria: [
        type: :string,
        doc: "Description of what 'passing' means beyond exit code 0"
      ],
      max_iterations: [
        type: :integer,
        doc: "Maximum number of test/fix cycles (default: 10)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  @impl true
  def run(params, context) do
    test_command = param!(params, :test_command)

    case Loomkin.ShellCommand.validate_command(test_command) do
      :ok ->
        do_start_loop(params, context, test_command)

      {:error, reason} ->
        {:error, "Invalid test command: #{reason}"}
    end
  end

  defp do_start_loop(params, context, test_command) do
    success_criteria = param(params, :success_criteria, nil)
    max_iterations = param(params, :max_iterations, 10)
    team_id = param!(context, :team_id)
    workspace_id = resolve_workspace_id(team_id)

    task_id =
      case context do
        %{task_id: id} when is_binary(id) -> id
        _ -> Ecto.UUID.generate()
      end

    loop_id = Ecto.UUID.generate()

    opts = [
      id: loop_id,
      workspace_id: workspace_id,
      team_id: team_id,
      task_id: task_id,
      test_command: test_command,
      success_criteria: success_criteria,
      max_iterations: max_iterations
    ]

    case DynamicSupervisor.start_child(
           Loomkin.Verification.Supervisor,
           {Loomkin.Verification.Loop, opts}
         ) do
      {:ok, _pid} ->
        {:ok,
         %{
           result:
             "Verification loop started (id: #{loop_id}). " <>
               "Running '#{test_command}' for up to #{max_iterations} iterations.",
           loop_id: loop_id
         }}

      {:error, reason} ->
        {:error, "Failed to start verification loop: #{inspect(reason)}"}
    end
  end

  defp resolve_workspace_id(team_id) do
    case Loomkin.Teams.Manager.get_team_meta(team_id) do
      {:ok, meta} -> meta[:workspace_id]
      _ -> nil
    end
  end
end
