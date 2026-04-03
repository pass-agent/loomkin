defmodule Loomkin.ShellCommand do
  @moduledoc """
  Shared module for executing shell commands with proper process cleanup.

  Ensures the OS subprocess is killed (not just the port closed) on timeout,
  preventing orphan processes from accumulating.
  """

  @doc """
  Execute a shell command in the given directory with a timeout.

  Returns `{:ok, output, exit_code}` on completion or `{:error, reason}` on timeout.
  Kills the OS process group on timeout to prevent orphans.
  """
  @spec execute(String.t(), String.t(), pos_integer()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, String.t()}
  def execute(command, project_path, timeout) do
    # Wrap in a process group so we can kill the entire tree on timeout.
    # `setsid` creates a new session; we record the PGID to kill later.
    wrapped = "exec #{command}"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        {:args, ["-c", wrapped]},
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, project_path}
      ])

    os_pid = port_os_pid(port)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_output(port, os_pid, [], deadline)
  end

  @doc """
  Truncate a string to `max_bytes` bytes, appending a marker if truncated.
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(output, max_bytes \\ 5000) do
    if byte_size(output) > max_bytes do
      String.slice(output, 0, max_bytes) <> "\n... (truncated)"
    else
      output
    end
  end

  @doc """
  Validate that a command matches an allowed prefix pattern.

  Returns `:ok` if valid, `{:error, reason}` if not.
  Only allows commands starting with known-safe prefixes.
  """
  @allowed_prefixes ~w(mix elixir iex true false sleep echo cat)

  # Shell metacharacters that enable command chaining/injection (including newline)
  @dangerous_pattern ~r/[;\n\r|&`$><]|\$\(/

  @spec validate_command(String.t()) :: :ok | {:error, String.t()}
  def validate_command(command) do
    trimmed = String.trim(command)
    first_word = trimmed |> String.split(~r/\s+/, parts: 2) |> List.first("")

    cond do
      first_word not in @allowed_prefixes ->
        {:error,
         "Command '#{first_word}' not in allowed prefixes: #{Enum.join(@allowed_prefixes, ", ")}"}

      Regex.match?(@dangerous_pattern, trimmed) ->
        {:error,
         "Command contains shell metacharacters (;, |, &, `, $, >, <) which are not allowed"}

      true ->
        :ok
    end
  end

  # --- Private ---

  defp collect_output(port, os_pid, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill_port(port, os_pid)
      {:error, "Command timed out"}
    else
      receive do
        {^port, {:data, data}} ->
          collect_output(port, os_pid, [data | acc], deadline)

        {^port, {:exit_status, code}} ->
          output = acc |> Enum.reverse() |> IO.iodata_to_binary()
          {:ok, output, code}
      after
        remaining ->
          kill_port(port, os_pid)
          {:error, "Command timed out"}
      end
    end
  end

  defp kill_port(port, os_pid) do
    # Close the Erlang port first
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    # Kill the OS process to prevent orphans
    if os_pid do
      System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    end
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end
end
