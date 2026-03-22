defmodule Loomkin.Tool do
  @moduledoc "Shared helpers for Loomkin tool actions."

  @doc """
  Validates that the given path does not escape `project_path`.

  Resolves symlinks so that a symlink pointing outside the project
  directory is correctly rejected. Falls back to the expanded path
  when the target does not yet exist (e.g. file creation).
  """
  @spec safe_path!(String.t(), String.t()) :: String.t()
  def safe_path!(file_path, project_path) do
    expanded = Path.expand(file_path, project_path)
    project_root = resolve_real(Path.expand(project_path))
    resolved = resolve_real(expanded)

    unless resolved == project_root or
             String.starts_with?(resolved, project_root <> "/") do
      raise ArgumentError, "Path #{file_path} is outside the project directory"
    end

    resolved
  end

  # Maximum symlink resolution depth to prevent hangs on symlink loops.
  @max_symlink_depth 40

  # Resolve symlinks by walking each path component. For components
  # that are symlinks, follow the link and continue. For non-existent
  # tails (file creation), resolve the parent and append the basename.
  defp resolve_real(path), do: resolve_real(path, @max_symlink_depth)

  defp resolve_real(_path, 0) do
    raise ArgumentError, "Too many levels of symlinks (possible symlink loop)"
  end

  defp resolve_real(path, depth) do
    parts = Path.split(path)

    Enum.reduce(parts, "", fn part, acc ->
      current = if acc == "", do: part, else: Path.join(acc, part)

      case File.read_link(current) do
        {:ok, target} ->
          absolute_target =
            if Path.type(target) == :absolute,
              do: target,
              else: Path.expand(target, Path.dirname(current))

          # The target itself might contain symlinks — resolve recursively
          resolve_real(absolute_target, depth - 1)

        {:error, _} ->
          current
      end
    end)
  end

  @doc """
  Resolves a file path relative to the project path without enforcing boundaries.

  Returns the fully resolved absolute path (with symlinks resolved).
  """
  @spec resolve_path(String.t(), String.t()) :: String.t()
  def resolve_path(file_path, project_path) do
    expanded = Path.expand(file_path, project_path)
    resolve_real(expanded)
  end

  @doc """
  Returns true if the resolved path is outside the project directory.
  """
  @spec outside_project?(String.t(), String.t()) :: boolean()
  def outside_project?(resolved_path, project_path) do
    project_root = resolve_real(Path.expand(project_path))

    not (resolved_path == project_root or
           String.starts_with?(resolved_path, project_root <> "/"))
  end

  @doc "Fetches a param by key, trying atom key first then string key."
  @spec param!(map(), atom()) :: any()
  def param!(params, key) when is_atom(key) do
    case Map.fetch(params, key) do
      {:ok, val} -> val
      :error -> Map.fetch!(params, Atom.to_string(key))
    end
  end

  @doc "Gets a param by key (atom or string fallback), with optional default."
  @spec param(map(), atom(), any()) :: any()
  def param(params, key, default \\ nil) when is_atom(key) do
    case Map.fetch(params, key) do
      {:ok, val} -> val
      :error -> Map.get(params, Atom.to_string(key), default)
    end
  end
end
