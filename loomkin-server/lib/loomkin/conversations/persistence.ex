defmodule Loomkin.Conversations.Persistence do
  @moduledoc """
  Database operations for conversation records.

  Conversations are persisted to the `conversations` table so that history
  and summaries survive process restarts.
  """

  alias Loomkin.Repo
  alias Loomkin.Schemas.Conversation
  import Ecto.Query

  @doc "List conversations for a team, most recent first."
  @spec list_for_team(String.t(), keyword()) :: [Conversation.t()]
  def list_for_team(team_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    Conversation
    |> where([c], c.team_id == ^team_id)
    |> maybe_filter_status(status)
    |> order_by([c], desc: c.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Get a single conversation by ID."
  @spec get(String.t()) :: Conversation.t() | nil
  def get(id) do
    Repo.get(Conversation, id)
  end

  @doc "Get the summary for a conversation, if it has one."
  @spec get_summary(String.t()) :: map() | nil
  def get_summary(id) do
    case Repo.get(Conversation, id) do
      %Conversation{summary: summary} when is_map(summary) -> summary
      _ -> nil
    end
  end

  @doc "List completed conversations with summaries for a team."
  @spec list_summaries(String.t(), keyword()) :: [Conversation.t()]
  def list_summaries(team_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Conversation
    |> where([c], c.team_id == ^team_id)
    |> where([c], c.status == "completed" and not is_nil(c.summary))
    |> order_by([c], desc: c.ended_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    where(query, [c], c.status == ^to_string(status))
  end
end
