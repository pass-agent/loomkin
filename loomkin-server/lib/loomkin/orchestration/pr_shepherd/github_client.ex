defmodule Loomkin.Orchestration.PRShepherd.GitHubClient do
  @moduledoc """
  Behaviour for fetching PR status (CI + review comments) from GitHub.

  Two implementations:

    * `Loomkin.Orchestration.PRShepherd.GitHubClient.Req` — real client backed
      by `Req` against `api.github.com`. Experimental; needs a GitHub auth
      token via the `:github_token` application env.
    * `Loomkin.Orchestration.PRShepherd.GitHubClient.Stub` — deterministic
      in-memory client used by tests.

  The active implementation is resolved via
  `Application.get_env(:loomkin, :pr_shepherd_client, ...)`.
  """

  @type pr_ref :: {owner :: String.t(), repo :: String.t(), pr_number :: pos_integer()}

  @type comment :: %{
          required(:id) => term(),
          required(:body) => String.t(),
          required(:resolved) => boolean(),
          optional(atom()) => term()
        }

  @type pr_status :: %{
          required(:ci) => :pending | :success | :failure,
          required(:comments) => [comment()]
        }

  @callback get_pr_status(pr_ref) :: {:ok, pr_status()} | {:error, term()}

  @doc """
  Returns the configured PR shepherd client module. Defaults to the Stub.
  """
  def impl,
    do:
      Application.get_env(
        :loomkin,
        :pr_shepherd_client,
        Loomkin.Orchestration.PRShepherd.GitHubClient.Stub
      )
end

defmodule Loomkin.Orchestration.PRShepherd.GitHubClient.Stub do
  @moduledoc """
  Deterministic stub used by tests and the default dev env.

  Canned responses can be stashed per `pr_ref` via `put_status/2`. If none is
  registered the stub returns `{:ok, %{ci: :pending, comments: []}}`.

  Backed by `:persistent_term` so it survives process restarts but is still
  trivially clearable between test cases.
  """

  @behaviour Loomkin.Orchestration.PRShepherd.GitHubClient

  @key {__MODULE__, :statuses}

  @doc "Stash a canned `%{ci:, comments:}` response (or an `{:error, _}` tuple) for a PR ref."
  def put_status(pr_ref, status_or_error) do
    map = current()
    :persistent_term.put(@key, Map.put(map, pr_ref, status_or_error))
    :ok
  end

  @doc "Clear all stashed responses. Idempotent."
  def reset do
    :persistent_term.put(@key, %{})
    :ok
  end

  @impl true
  def get_pr_status(pr_ref) do
    case Map.get(current(), pr_ref) do
      nil -> {:ok, %{ci: :pending, comments: []}}
      {:error, _} = err -> err
      %{} = status -> {:ok, status}
    end
  end

  defp current do
    try do
      :persistent_term.get(@key)
    rescue
      ArgumentError -> %{}
    end
  end
end

defmodule Loomkin.Orchestration.PRShepherd.GitHubClient.Req do
  @moduledoc """
  Experimental; needs GitHub auth token via `:github_token` application env.

  Hits two endpoints per call:

    * `GET /repos/:owner/:repo/commits/:sha/status` for the combined CI status
    * `GET /repos/:owner/:repo/pulls/:number/comments` for review comments

  The CI status maps as: "success" → `:success`, "failure"/"error" → `:failure`,
  anything else (including "pending") → `:pending`. Comments are normalised to
  the `%{id:, body:, resolved:}` shape the shepherd consumes.
  """

  @behaviour Loomkin.Orchestration.PRShepherd.GitHubClient

  @base_url "https://api.github.com"

  @impl true
  def get_pr_status({owner, repo, pr_number}) do
    with {:ok, pr} <- get_pr(owner, repo, pr_number),
         sha when is_binary(sha) <- get_in(pr, ["head", "sha"]) || pr["head_sha"],
         {:ok, ci} <- get_ci(owner, repo, sha),
         {:ok, comments} <- get_comments(owner, repo, pr_number) do
      {:ok, %{ci: ci, comments: comments}}
    else
      {:error, _} = err -> err
      other -> {:error, {:unexpected, other}}
    end
  end

  defp get_pr(owner, repo, pr_number) do
    request("/repos/#{owner}/#{repo}/pulls/#{pr_number}")
  end

  defp get_ci(owner, repo, sha) do
    case request("/repos/#{owner}/#{repo}/commits/#{sha}/status") do
      {:ok, %{"state" => state}} -> {:ok, normalize_ci(state)}
      {:ok, _} -> {:ok, :pending}
      {:error, _} = err -> err
    end
  end

  defp get_comments(owner, repo, pr_number) do
    case request("/repos/#{owner}/#{repo}/pulls/#{pr_number}/comments") do
      {:ok, comments} when is_list(comments) ->
        {:ok, Enum.map(comments, &normalize_comment/1)}

      {:ok, _} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_ci("success"), do: :success
  defp normalize_ci(state) when state in ["failure", "error"], do: :failure
  defp normalize_ci(_), do: :pending

  defp normalize_comment(%{} = c) do
    %{
      id: c["id"],
      body: c["body"] || "",
      # GitHub's REST PR-comments endpoint doesn't expose thread-resolution; treat
      # everything as unresolved by default so the shepherd flags it.
      resolved: false,
      user: get_in(c, ["user", "login"]),
      path: c["path"]
    }
  end

  defp request(path) do
    token = Application.get_env(:loomkin, :github_token)

    headers =
      [{"accept", "application/vnd.github+json"}] ++
        if(token, do: [{"authorization", "Bearer #{token}"}], else: [])

    case Req.get(@base_url <> path, headers: headers, receive_timeout: 5_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e}}
  end
end
