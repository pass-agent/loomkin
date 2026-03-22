defmodule Loomkin.Permissions.Hooks.CompilationHook do
  @moduledoc """
  Post-tool hook that runs `mix compile --warnings-as-errors` after file writes.

  Only triggers for `file_write` and `file_edit` tools. Returns `:ok` on
  successful compilation or `{:warn, message}` when compilation produces
  warnings or errors.
  """

  @behaviour Loomkin.Permissions.Hook

  @write_tools ["file_write", "file_edit"]

  @impl true
  def name, do: "compilation"

  @impl true
  def description, do: "Runs mix compile after file modifications"

  @impl true
  def post_tool(tool_name, _tool_args, _result) when tool_name in @write_tools do
    case System.cmd("mix", ["compile", "--warnings-as-errors"],
           stderr_to_stdout: true,
           cd: project_path()
         ) do
      {_output, 0} -> :ok
      {output, _} -> {:warn, "Compilation warning: #{String.slice(output, 0, 500)}"}
    end
  end

  def post_tool(_tool_name, _tool_args, _result), do: :ok

  defp project_path do
    # Read from process dictionary (set by agent loop) or fallback to cwd
    Process.get(:loomkin_project_path) || File.cwd!()
  end
end
