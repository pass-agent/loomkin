defmodule Loomkin.Tools.ShellSession do
  @moduledoc """
  Lightweight ETS-backed persistent shell sessions for agents.

  Each agent gets a per-agent shell context (`cwd` and `env`) keyed by
  `{team_id, agent_name}`. The shell tool reads this context before
  executing commands, and updates it afterwards when `cd` or `export`
  changes are detected.

  The ETS table is created in `Loomkin.Application.start/2` and cleaned
  up per-agent in `Loomkin.Teams.Agent.terminate/2`.
  """

  @table :loomkin_shell_sessions

  @type agent_key :: {team_id :: String.t(), agent_name :: atom() | String.t()}
  @type session :: %{cwd: String.t(), env: %{String.t() => String.t()}}

  @doc """
  Returns the ETS table name (used in Application to create the table).
  """
  def table_name, do: @table

  @doc """
  Initializes a session for the given agent with the provided project path
  as the initial working directory. No-op if a session already exists.
  """
  @spec init_session(agent_key(), String.t()) :: :ok
  def init_session(key, project_path) do
    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert(@table, {key, %{cwd: project_path, env: %{}}})
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Returns the current session for an agent, or `nil` if none exists.
  """
  @spec get(agent_key()) :: session() | nil
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, session}] -> session
      [] -> nil
    end
  end

  @doc """
  Returns the current working directory for an agent, falling back to the
  given default if no session exists.
  """
  @spec get_cwd(agent_key(), String.t()) :: String.t()
  def get_cwd(key, default) do
    case get(key) do
      %{cwd: cwd} -> cwd
      nil -> default
    end
  end

  @doc """
  Returns the environment variables map for an agent session.
  """
  @spec get_env(agent_key()) :: %{String.t() => String.t()}
  def get_env(key) do
    case get(key) do
      %{env: env} -> env
      nil -> %{}
    end
  end

  @doc """
  Updates the working directory for an agent session.
  Initializes the session if it doesn't exist.
  """
  @spec update_cwd(agent_key(), String.t()) :: :ok
  def update_cwd(key, new_cwd) do
    case :ets.lookup(@table, key) do
      [{^key, session}] ->
        :ets.insert(@table, {key, %{session | cwd: new_cwd}})
        :ok

      [] ->
        :ets.insert(@table, {key, %{cwd: new_cwd, env: %{}}})
        :ok
    end
  end

  @doc """
  Merges environment variables into the agent's session.
  Initializes the session if it doesn't exist.
  """
  @spec merge_env(agent_key(), %{String.t() => String.t()}) :: :ok
  def merge_env(_key, env) when map_size(env) == 0, do: :ok

  def merge_env(key, new_env) do
    case :ets.lookup(@table, key) do
      [{^key, session}] ->
        :ets.insert(@table, {key, %{session | env: Map.merge(session.env, new_env)}})
        :ok

      [] ->
        # Session should already exist via init_session; skip merge if missing
        # to avoid creating a session with an unsafe default CWD.
        :ok
    end
  end

  @doc """
  Removes the session for an agent. Called on agent termination.
  """
  @spec cleanup(agent_key()) :: :ok
  def cleanup(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Extracts `export KEY=VALUE` patterns from a command string and returns
  a map of environment variable assignments.
  """
  @spec extract_exports(String.t()) :: %{String.t() => String.t()}
  def extract_exports(command) do
    ~r/\bexport\s+([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|\S+)/
    |> Regex.scan(command)
    |> Enum.reduce(%{}, fn
      [_, key, value], acc ->
        # Strip surrounding quotes if present
        value = value |> String.trim_leading("\"") |> String.trim_trailing("\"")
        value = value |> String.trim_leading("'") |> String.trim_trailing("'")
        Map.put(acc, key, value)
    end)
  end

  @doc """
  Given the raw output from a command that had `; echo __LOOMKIN_CWD__; pwd`
  appended, extracts the actual CWD from the output and strips the sentinel
  lines.

  Returns `{cleaned_output, new_cwd}` or `{output, nil}` if the sentinel
  was not found.
  """
  @spec extract_cwd_from_output(String.t()) :: {String.t(), String.t() | nil}
  def extract_cwd_from_output(output) do
    case String.split(output, "__LOOMKIN_CWD__\n", parts: 2) do
      [before, after_sentinel] ->
        # The first line after the sentinel is the pwd output
        case String.split(after_sentinel, "\n", parts: 2) do
          [cwd_line, rest] ->
            cwd = String.trim(cwd_line)
            cleaned = String.trim_trailing(before) <> if(rest != "", do: "\n" <> rest, else: "")
            {cleaned, cwd}

          [cwd_line] ->
            {String.trim_trailing(before), String.trim(cwd_line)}
        end

      [_no_match] ->
        {output, nil}
    end
  end

  @doc """
  Wraps a command to capture CWD after execution by appending a sentinel
  and `pwd`.
  """
  @spec wrap_command_for_cwd_tracking(String.t()) :: String.t()
  def wrap_command_for_cwd_tracking(command) do
    command <> " ; echo __LOOMKIN_CWD__ ; pwd"
  end
end
