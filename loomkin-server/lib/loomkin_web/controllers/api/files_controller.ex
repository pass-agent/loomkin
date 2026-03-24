defmodule LoomkinWeb.Api.FilesController do
  use LoomkinWeb, :controller

  @doc "GET /api/v1/files?path=<dir>"
  def index(conn, params) do
    project_path = project_path(conn)
    dir = params["path"] || "."

    case Loomkin.Tools.DirectoryList.run(%{path: dir}, %{project_path: project_path}) do
      {:ok, %{result: result}} ->
        entries = parse_directory_listing(result)
        json(conn, %{path: dir, entries: entries})

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: reason})
    end
  end

  @doc "GET /api/v1/files/read?path=<file>&offset=<n>&limit=<n>"
  def read(conn, params) do
    project_path = project_path(conn)
    file_path = params["path"] || ""

    tool_params =
      %{file_path: file_path}
      |> maybe_put(:offset, params["offset"])
      |> maybe_put(:limit, params["limit"])

    case Loomkin.Tools.FileRead.run(tool_params, %{project_path: project_path}) do
      {:ok, %{result: result}} ->
        json(conn, %{content: result})

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: reason})
    end
  end

  @doc "GET /api/v1/files/search?pattern=<glob>&path=<dir>"
  def search(conn, params) do
    project_path = project_path(conn)
    pattern = params["pattern"] || "**/*"
    path = params["path"]

    tool_params = %{pattern: pattern}
    tool_params = if path, do: Map.put(tool_params, :path, path), else: tool_params

    case Loomkin.Tools.FileSearch.run(tool_params, %{project_path: project_path}) do
      {:ok, %{result: result}} ->
        files = parse_file_list(result)
        json(conn, %{pattern: pattern, files: files})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  @doc "GET /api/v1/files/grep?pattern=<regex>&path=<dir>&glob=<filter>"
  def grep(conn, params) do
    project_path = project_path(conn)
    pattern = params["pattern"] || ""
    path = params["path"]
    glob = params["glob"]

    tool_params = %{pattern: pattern}
    tool_params = if path, do: Map.put(tool_params, :path, path), else: tool_params
    tool_params = if glob, do: Map.put(tool_params, :glob, glob), else: tool_params

    case Loomkin.Tools.ContentSearch.run(tool_params, %{project_path: project_path}) do
      {:ok, %{result: result}} ->
        matches = parse_grep_results(result)
        json(conn, %{pattern: pattern, matches: matches})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  # --- Helpers ---

  defp project_path(conn) do
    case conn.assigns[:current_scope] do
      %{user: _user} -> Loomkin.Config.project_path()
      _ -> Loomkin.Config.project_path()
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val) when is_binary(val), do: Map.put(map, key, String.to_integer(val))
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp parse_directory_listing(result) do
    result
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      # Format: "type  size  date  name/"
      parts = String.split(line, ~r/\s{2,}/, parts: 4)

      case parts do
        [type, size, date, name] ->
          is_dir = String.ends_with?(name, "/")
          clean_name = String.trim_trailing(name, "/")
          %{name: clean_name, type: String.trim(type), size: size, modified: date, is_dir: is_dir}

        _ ->
          %{name: String.trim(line), type: "unknown", size: "?", modified: "?", is_dir: false}
      end
    end)
  end

  defp parse_file_list(result) do
    result
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_grep_results(result) do
    result
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 3) do
        [file, line_num, content] ->
          %{file: file, line: String.to_integer(line_num), content: content}

        _ ->
          %{file: line, line: 0, content: ""}
      end
    end)
  end
end
