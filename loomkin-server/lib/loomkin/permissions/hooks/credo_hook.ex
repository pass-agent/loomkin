defmodule Loomkin.Permissions.Hooks.CredoHook do
  @moduledoc """
  Post-tool hook that runs `mix credo --strict` on modified files.

  Only triggers for `file_write` and `file_edit` tools, and only for `.ex` or
  `.exs` files. Returns `:ok` when Credo finds no issues or `{:warn, message}`
  when issues are detected.
  """

  @behaviour Loomkin.Permissions.Hook

  @write_tools ["file_write", "file_edit"]
  @elixir_extensions [".ex", ".exs"]

  @impl true
  def name, do: "credo"

  @impl true
  def description, do: "Runs Credo analysis on modified files"

  @impl true
  def post_tool(tool_name, tool_args, _result) when tool_name in @write_tools do
    file_path = tool_args["path"] || tool_args["file_path"] || ""

    if elixir_file?(file_path) do
      case System.cmd("mix", ["credo", "--strict", "--files-included", file_path],
             stderr_to_stdout: true,
             cd: project_path()
           ) do
        {_output, 0} -> :ok
        {output, _} -> {:warn, "Credo issues: #{String.slice(output, 0, 500)}"}
      end
    else
      :ok
    end
  end

  def post_tool(_tool_name, _tool_args, _result), do: :ok

  defp elixir_file?(path) do
    Enum.any?(@elixir_extensions, &String.ends_with?(path, &1))
  end

  defp project_path do
    Process.get(:loomkin_project_path) || File.cwd!()
  end
end
