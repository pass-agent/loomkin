defmodule Loomkin.Session.Persistence do
  @moduledoc "Database operations for sessions and messages."

  alias Loomkin.Repo
  alias Loomkin.Schemas.Message
  alias Loomkin.Schemas.Session
  import Ecto.Query

  @spec create_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(attrs) do
    # If an explicit id is provided, set it on the struct before changeset
    # since id is a primary key and not included in cast fields
    base =
      case Map.get(attrs, :id) || Map.get(attrs, "id") do
        nil -> %Session{}
        id -> %Session{id: id}
      end

    base
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_session(String.t()) :: Session.t() | nil
  def get_session(id) do
    Repo.get(Session, id)
  end

  @spec list_sessions(keyword()) :: [Session.t()]
  def list_sessions(opts \\ []) do
    Session
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_project_path(opts[:project_path])
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
  end

  @spec update_session(Session.t(), map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_session(session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  @spec archive_session(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def archive_session(session) do
    update_session(session, %{status: :archived})
  end

  @spec save_message(map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def save_message(attrs) do
    result =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, msg} ->
        Loomkin.Telemetry.emit_session_message(%{
          session_id: msg.session_id,
          role: msg.role,
          token_count: msg.token_count
        })

        {:ok, msg}

      error ->
        error
    end
  end

  @doc """
  Atomically save a user+assistant message pair in a single transaction.
  Prevents orphaned messages if a crash occurs between saves.
  """
  @spec save_exchange(String.t(), String.t(), String.t()) ::
          {:ok, %{user: Message.t(), assistant: Message.t()}} | {:error, term()}
  def save_exchange(session_id, user_content, assistant_content) do
    Repo.transaction(fn ->
      {:ok, user_msg} =
        %Message{}
        |> Message.changeset(%{session_id: session_id, role: :user, content: user_content})
        |> Repo.insert()

      {:ok, assistant_msg} =
        %Message{}
        |> Message.changeset(%{
          session_id: session_id,
          role: :assistant,
          content: assistant_content
        })
        |> Repo.insert()

      Loomkin.Telemetry.emit_session_message(%{
        session_id: session_id,
        role: :user,
        token_count: user_msg.token_count
      })

      Loomkin.Telemetry.emit_session_message(%{
        session_id: session_id,
        role: :assistant,
        token_count: assistant_msg.token_count
      })

      %{user: user_msg, assistant: assistant_msg}
    end)
  end

  @spec load_messages(String.t()) :: [Message.t()]
  def load_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  @spec update_costs(String.t(), integer(), integer(), Decimal.t() | number()) ::
          :ok | {:error, :not_found}
  def update_costs(session_id, prompt_tokens, completion_tokens, cost_usd) do
    cost_float =
      case cost_usd do
        %Decimal{} -> Decimal.to_float(cost_usd)
        n when is_number(n) -> n / 1
        _ -> 0.0
      end

    {count, _} =
      Session
      |> where([s], s.id == ^session_id)
      |> update([s], inc: [prompt_tokens: ^prompt_tokens, completion_tokens: ^completion_tokens])
      |> update([s], set: [cost_usd: fragment("COALESCE(?, 0) + ?", s.cost_usd, ^cost_float)])
      |> Repo.update_all([])

    if count > 0, do: :ok, else: {:error, :not_found}
  end

  @spec find_latest_active_session(String.t()) :: Session.t() | nil
  def find_latest_active_session(project_path) do
    Session
    |> where([s], s.project_path == ^project_path and s.status == :active)
    |> order_by([s], desc: s.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec list_projects() :: [map()]
  def list_projects do
    Session
    |> group_by([s], s.project_path)
    |> select([s], %{
      project_path: s.project_path,
      session_count: count(s.id),
      last_active_at: max(s.updated_at)
    })
    |> order_by([s], desc: max(s.updated_at))
    |> Repo.all()
  end

  @spec list_sessions_for_project(String.t()) :: [Session.t()]
  def list_sessions_for_project(project_path) do
    list_sessions(project_path: project_path)
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    where(query, [s], s.status == ^status)
  end

  defp maybe_filter_project_path(query, nil), do: query

  defp maybe_filter_project_path(query, path) do
    where(query, [s], s.project_path == ^path)
  end
end
