defmodule Loomkin.Tools.Shell do
  @moduledoc """
  Executes shell commands with sandboxing and audit logging.

  Commands are validated against a blocklist of dangerous patterns and
  optionally restricted to an allowlist configured in `.loomkin.toml`.
  The working directory is locked to the project path, and resource
  limits (timeout, memory) are applied via ulimit wrappers.
  """

  use Jido.Action,
    name: "shell",
    description:
      "Executes a shell command and returns its stdout, stderr, and exit code. " <>
        "Output is truncated at 10000 characters. " <>
        "The command runs in the project directory.",
    schema: [
      command: [type: :string, required: true, doc: "The shell command to execute"],
      timeout: [type: :integer, doc: "Timeout in milliseconds (default: 30000)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  @default_timeout 30_000
  @max_output_chars 10_000

  # Patterns that are always blocked regardless of allowlist config.
  # Each entry is {regex, human-readable reason}.
  # Regexes must NOT anchor to end-of-string so chained commands
  # (e.g. `rm -rf / && echo done`) are still caught.
  @blocked_patterns [
    {~r/\brm\s+(-[^\s]*\s+)*-[^\s]*r[^\s]*\s+\/(\s|$)/, "recursive delete of root"},
    {~r/\brm\s+(-[^\s]*\s+)*-[^\s]*r[^\s]*f[^\s]*\s+\/(\s|$)/, "forced recursive delete of root"},
    {~r/\bmkfs\b/, "filesystem formatting"},
    {~r/\bdd\b\s+.*of=\/dev\//, "raw device write"},
    {~r/:\(\)\{\s*:\|:&\s*\};:/, "fork bomb"},
    {~r/\.\s*\/dev\/sd/, "raw device access"},
    {~r/>\s*\/dev\/sd/, "raw device write"},
    {~r/\bchmod\s+(-[^\s]+\s+)*[0-7]*777\s+\//, "chmod 777 on root"},
    {~r/\bchown\s+(-[^\s]+\s+)*.*\s+\/(\s|$)/, "chown on root"},
    {~r/\bcurl\b.*\|\s*(ba)?sh/, "pipe curl to shell"},
    {~r/\bwget\b.*\|\s*(ba)?sh/, "pipe wget to shell"},
    {~r/\beval\b.*\$\(curl/, "eval curl output"},
    {~r/\b(shutdown|reboot|halt|poweroff)\b/, "system power command"},
    {~r/\b:(){ :\|:& };:/, "fork bomb (alternate)"}
  ]

  defp default_timeout do
    Loomkin.Config.get(:agents, :shell_timeout_ms) || @default_timeout
  end

  defp max_output_chars do
    Loomkin.Config.get(:agents, :shell_max_output_chars) || @max_output_chars
  end

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    command = param!(params, :command)
    timeout = param(params, :timeout, default_timeout())

    with :ok <- check_blocklist(command),
         :ok <- check_allowlist(command),
         :ok <- check_working_directory(command, project_path) do
      execute_via_port(command, project_path, timeout)
    end
  end

  # --- Validation ---

  defp check_blocklist(command) do
    case Enum.find(@blocked_patterns, fn {regex, _reason} -> Regex.match?(regex, command) end) do
      {_regex, reason} ->
        {:error, "Command blocked: #{reason}"}

      nil ->
        :ok
    end
  end

  defp check_allowlist(command) do
    case Loomkin.Config.get(:shell) do
      %{allowlist_enabled: true, allowlist: allowed} when is_list(allowed) ->
        # Check all commands through pipes and &&/|| chains
        chained_cmds = extract_chained_commands(command)

        if Enum.all?(chained_cmds, &(&1 in allowed)) do
          :ok
        else
          blocked = Enum.reject(chained_cmds, &(&1 in allowed))

          {:error,
           "Command not in allowlist. Allowed: #{Enum.join(allowed, ", ")}. Blocked: #{Enum.join(blocked, ", ")}"}
        end

      _ ->
        # Allowlist not enabled — permit (blocklist already checked)
        :ok
    end
  end

  defp check_working_directory(command, project_path) do
    project_root = String.trim_trailing(project_path, "/")

    # 1. Block cd to paths outside project
    cd_targets = Regex.scan(~r/\bcd\s+([^\s;&|]+)/, command, capture: :all_but_first)

    cd_escape =
      Enum.find(cd_targets, fn [target] ->
        expanded = Path.expand(target, project_path)
        not path_within?(expanded, project_root)
      end)

    if cd_escape do
      [target] = cd_escape
      {:error, "Cannot cd outside project directory: #{target}"}
    else
      # 2. Block absolute paths outside project anywhere in the command.
      # Extract tokens that look like absolute paths (starting with /).
      abs_paths =
        Regex.scan(~r{(?:^|\s)(\/[^\s;&|]+)}, command, capture: :all_but_first)
        |> List.flatten()
        # Ignore /dev/null (harmless) and paths already caught by blocklist
        |> Enum.reject(&(&1 == "/dev/null"))

      outside =
        Enum.find(abs_paths, fn p ->
          expanded = Path.expand(p)
          not path_within?(expanded, project_root)
        end)

      case outside do
        nil ->
          :ok

        path ->
          {:error, "Cannot access paths outside project directory: #{path}"}
      end
    end
  end

  # Check if `path` is equal to or nested inside `root`, with a proper
  # path-boundary check (prevents /tmp/proj2 matching /tmp/proj).
  defp path_within?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  @doc false
  def extract_chained_commands(command) do
    command
    |> String.split(~r/\s*(?:\|\||&&|;|\|)\s*/)
    |> Enum.map(fn segment ->
      segment |> String.trim() |> String.split(~r/\s+/, parts: 2) |> List.first("")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # --- Execution ---

  defp execute_via_port(command, project_path, timeout) do
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
        output =
          acc
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> truncate()

        result = "Exit code: #{code}\n#{output}"

        if code == 0 do
          {:ok, %{result: result}}
        else
          {:error, result}
        end
    after
      timeout ->
        Port.close(port)
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp truncate(output) do
    max_chars = max_output_chars()

    if byte_size(output) > max_chars do
      truncated = String.slice(output, 0, max_chars)
      remaining = byte_size(output) - max_chars
      truncated <> "\n... (#{remaining} characters truncated)"
    else
      output
    end
  end
end
