defmodule LoomkinWeb.Api.SessionController do
  use LoomkinWeb, :controller

  alias Loomkin.Session.Persistence

  action_fallback LoomkinWeb.Api.FallbackController

  @doc "GET /api/v1/sessions"
  def index(conn, params) do
    user = conn.assigns.current_scope.user

    opts =
      [user: user]
      |> maybe_add(:status, params["status"], &String.to_existing_atom/1)
      |> maybe_add(:limit, params["limit"], &String.to_integer/1)
      |> maybe_add(:project_path, params["project_path"])

    sessions = Persistence.list_sessions(opts)
    json(conn, %{sessions: Enum.map(sessions, &serialize_session/1)})
  end

  @doc "GET /api/v1/sessions/:id"
  def show(conn, %{"id" => id}) do
    case Persistence.get_session(id) do
      nil -> {:error, :not_found}
      session -> json(conn, %{session: serialize_session(session)})
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc "POST /api/v1/sessions"
  def create(conn, %{"session" => params}) do
    user = conn.assigns.current_scope.user
    attrs = Map.put(params, "user_id", user.id)

    case Persistence.create_session(attrs) do
      {:ok, session} ->
        conn
        |> put_status(:created)
        |> json(%{session: serialize_session(session)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "GET /api/v1/sessions/:id/messages"
  def messages(conn, %{"id" => id}) do
    case Persistence.get_session(id) do
      nil ->
        {:error, :not_found}

      _session ->
        messages = Persistence.load_messages(id)
        json(conn, %{messages: Enum.map(messages, &serialize_message/1)})
    end
  end

  @doc "POST /api/v1/sessions/:id/messages"
  def send_message(conn, %{"id" => id, "message" => message_params}) do
    case Persistence.get_session(id) do
      nil ->
        {:error, :not_found}

      _session ->
        attrs = Map.put(message_params, "session_id", id)

        case Persistence.save_message(attrs) do
          {:ok, message} ->
            conn
            |> put_status(:created)
            |> json(%{message: serialize_message(message)})

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc "PATCH /api/v1/sessions/:id"
  def update(conn, %{"id" => id, "session" => params}) do
    case Persistence.get_session(id) do
      nil ->
        {:error, :not_found}

      session ->
        allowed = Map.take(params, ["title"])

        case Persistence.update_session(session, allowed) do
          {:ok, session} -> json(conn, %{session: serialize_session(session)})
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @doc "PATCH /api/v1/sessions/:id/archive"
  def archive(conn, %{"id" => id}) do
    case Persistence.get_session(id) do
      nil ->
        {:error, :not_found}

      session ->
        case Persistence.archive_session(session) do
          {:ok, session} -> json(conn, %{session: serialize_session(session)})
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp serialize_session(session) do
    %{
      id: session.id,
      title: session.title,
      status: session.status,
      model: session.model,
      fast_model: session.fast_model,
      project_path: session.project_path,
      prompt_tokens: session.prompt_tokens,
      completion_tokens: session.completion_tokens,
      cost_usd: session.cost_usd && Decimal.to_float(session.cost_usd),
      team_id: session.team_id,
      inserted_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end

  defp serialize_message(message) do
    %{
      id: message.id,
      role: message.role,
      content: message.content,
      tool_calls: message.tool_calls,
      tool_call_id: message.tool_call_id,
      token_count: message.token_count,
      agent_name: message.agent_name,
      inserted_at: message.inserted_at
    }
  end

  defp maybe_add(opts, _key, nil, _transform), do: opts

  defp maybe_add(opts, key, value, transform) do
    Keyword.put(opts, key, transform.(value))
  rescue
    _ -> opts
  end

  defp maybe_add(opts, _key, nil), do: opts

  defp maybe_add(opts, key, value) do
    Keyword.put(opts, key, value)
  end
end
