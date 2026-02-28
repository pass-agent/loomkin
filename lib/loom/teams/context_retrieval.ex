defmodule Loom.Teams.ContextRetrieval do
  @moduledoc "How agents find and retrieve context from keepers."

  alias Loom.Teams.ContextKeeper

  @default_max_tokens 8000

  @doc """
  List all keepers for a team.

  Returns a list of maps: `[%{id: id, topic: topic, source_agent: source_agent, token_count: count}]`
  """
  def list_keepers(team_id) do
    Registry.select(Loom.Teams.AgentRegistry, [
      {{{team_id, :"$1"}, :"$2", :"$3"}, [], [%{name: :"$1", pid: :"$2", meta: :"$3"}]}
    ])
    |> Enum.filter(fn %{meta: meta} -> meta[:type] == :keeper end)
    |> Enum.map(fn %{name: name, pid: pid, meta: meta} ->
      # name is "keeper:<id>"
      id = String.replace_prefix(to_string(name), "keeper:", "")

      %{
        id: id,
        pid: pid,
        topic: meta[:topic] || "unnamed",
        source_agent: meta[:source_agent] || "unknown",
        token_count: meta[:tokens] || 0
      }
    end)
  end

  @doc """
  Search keepers by relevance to a query.

  Scores keepers by topic similarity and returns sorted results.
  """
  def search(team_id, query) do
    query_words =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> MapSet.new()

    list_keepers(team_id)
    |> Enum.map(fn keeper ->
      topic_words =
        keeper.topic
        |> String.downcase()
        |> String.split(~r/\s+/, trim: true)
        |> MapSet.new()

      relevance = MapSet.intersection(query_words, topic_words) |> MapSet.size()

      Map.put(keeper, :relevance, relevance)
    end)
    |> Enum.sort_by(& &1.relevance, :desc)
  end

  @doc """
  Retrieve context from a specific keeper or search all.

  Options:
    - `:keeper_id` - retrieve from a specific keeper
    - `:max_tokens` - maximum tokens to return (default 8000)
    - `:mode` - `:smart` for LLM-summarized answers, `:raw` for raw messages.
      When omitted, auto-detected from query (questions → :smart, keywords → :raw).

  Returns `{:ok, messages}` or `{:error, :not_found}`.
  """
  def retrieve(team_id, query, opts \\ []) do
    keeper_id = Keyword.get(opts, :keeper_id)
    _max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    mode = Keyword.get(opts, :mode, detect_mode(query))

    if keeper_id do
      retrieve_from_keeper(team_id, keeper_id, query, mode)
    else
      retrieve_from_best(team_id, query, mode)
    end
  end

  @doc "Smart retrieval — asks keepers a question and gets a focused answer."
  def smart_retrieve(team_id, question, opts \\ []) do
    retrieve(team_id, question, Keyword.put(opts, :mode, :smart))
  end

  # --- Private ---

  @question_starters ~w(what how why where when who which did does is are was were can could should would)

  @doc false
  def detect_mode(query) do
    downcased = String.downcase(String.trim(query))

    cond do
      String.contains?(query, "?") -> :smart
      Enum.any?(@question_starters, &String.starts_with?(downcased, &1 <> " ")) -> :smart
      true -> :raw
    end
  end

  defp retrieve_from_keeper(team_id, keeper_id, query, mode) do
    case Registry.lookup(Loom.Teams.AgentRegistry, {team_id, "keeper:#{keeper_id}"}) do
      [{pid, _meta}] ->
        case mode do
          :smart -> ContextKeeper.smart_retrieve(pid, query)
          :raw -> ContextKeeper.retrieve(pid, query)
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp retrieve_from_best(team_id, query, mode) do
    case search(team_id, query) |> Enum.filter(&(&1.relevance > 0)) do
      [best | _rest] ->
        case mode do
          :smart -> ContextKeeper.smart_retrieve(best.pid, query)
          :raw -> ContextKeeper.retrieve(best.pid, query)
        end

      [] ->
        {:error, :not_found}
    end
  end
end
