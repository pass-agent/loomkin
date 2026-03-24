defmodule LoomkinWeb.Api.DiffController do
  use LoomkinWeb, :controller

  @doc "GET /api/v1/diff?file=<path>&staged=<bool>"
  def index(conn, params) do
    project_path = Loomkin.Config.project_path()
    staged = params["staged"] == "true"
    file = params["file"]

    args = %{}
    args = if staged, do: Map.put(args, :staged, true), else: args
    args = if file, do: Map.put(args, :file, file), else: args

    case Loomkin.Tools.Git.run(
           %{operation: "diff", args: args},
           %{project_path: project_path}
         ) do
      {:ok, %{result: result}} ->
        json(conn, %{diff: result})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end
end
