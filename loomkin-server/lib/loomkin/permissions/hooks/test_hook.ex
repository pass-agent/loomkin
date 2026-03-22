defmodule Loomkin.Permissions.Hooks.TestHook do
  @moduledoc """
  Post-tool hook that runs `mix test --failed` after file writes.

  Only triggers for `file_write` and `file_edit` tools. Runs previously-failed
  tests with a max failure cap to keep feedback fast. Returns `:ok` when tests
  pass or `{:warn, message}` when failures are detected.
  """

  @behaviour Loomkin.Permissions.Hook

  @write_tools ["file_write", "file_edit"]

  @impl true
  def name, do: "test"

  @impl true
  def description, do: "Runs failed tests after file modifications"

  @impl true
  def post_tool(tool_name, _tool_args, _result) when tool_name in @write_tools do
    case System.cmd("mix", ["test", "--failed", "--max-failures", "3"],
           stderr_to_stdout: true,
           cd: project_path(),
           env: [{"MIX_ENV", "test"}]
         ) do
      {_output, 0} -> :ok
      {output, _} -> {:warn, "Test failures: #{String.slice(output, 0, 500)}"}
    end
  end

  def post_tool(_tool_name, _tool_args, _result), do: :ok

  defp project_path do
    Process.get(:loomkin_project_path) || File.cwd!()
  end
end
