defmodule Loom.Teams.ContextKeeper do
  @moduledoc """
  GenServer that holds conversation context for a team.

  Supports both raw retrieval (keyword matching) and smart retrieval
  (single LLM call to answer questions about stored context).

  Registered in AgentRegistry as `{team_id, "keeper:<id>"}` with
  metadata `%{type: :keeper, topic: topic, tokens: count}`.
  """

  use GenServer

  alias Loom.Repo
  alias Loom.Schemas.ContextKeeper, as: KeeperSchema

  require Logger

  @chars_per_token 4
  @keyword_match_budget 10_000
  @persist_debounce_ms 50

  defstruct [
    :id,
    :team_id,
    :topic,
    :source_agent,
    :created_at,
    messages: [],
    token_count: 0,
    metadata: %{},
    dirty: false,
    persist_ref: nil,
    persist_debounce_ms: @persist_debounce_ms
  ]

  # --- Public API ---

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    team_id = Keyword.fetch!(opts, :team_id)
    topic = Keyword.get(opts, :topic, "unnamed")
    source_agent = Keyword.get(opts, :source_agent, "unknown")

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {Loom.Teams.AgentRegistry, {team_id, "keeper:#{id}"},
          %{type: :keeper, topic: topic, tokens: 0, source_agent: source_agent}}}
    )
  end

  @doc "Store messages and metadata in this keeper."
  def store(pid, messages, metadata \\ %{}) do
    GenServer.call(pid, {:store, messages, metadata})
  end

  @doc "Retrieve all stored messages."
  def retrieve_all(pid) do
    GenServer.call(pid, :retrieve_all)
  end

  @doc "Retrieve messages relevant to a query."
  def retrieve(pid, query) do
    GenServer.call(pid, {:retrieve, query})
  end

  @doc "Get a one-line index entry for an agent's context window."
  def index_entry(pid) do
    GenServer.call(pid, :index_entry)
  end

  @doc "Query this keeper with a smart LLM-powered retrieval."
  def smart_retrieve(pid, question) do
    GenServer.call(pid, {:smart_retrieve, question}, 30_000)
  end

  @doc "Get full state for debugging."
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc false
  def flush_persist(pid) do
    GenServer.call(pid, :flush_persist)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    team_id = Keyword.fetch!(opts, :team_id)
    topic = Keyword.get(opts, :topic, "unnamed")
    source_agent = Keyword.get(opts, :source_agent, "unknown")
    messages = Keyword.get(opts, :messages, [])
    metadata = Keyword.get(opts, :metadata, %{})
    persist_debounce_ms = Keyword.get(opts, :persist_debounce_ms, @persist_debounce_ms)

    token_count = estimate_tokens(messages)

    state = %__MODULE__{
      id: id,
      team_id: team_id,
      topic: topic,
      source_agent: source_agent,
      messages: messages,
      token_count: token_count,
      metadata: metadata,
      created_at: DateTime.utc_now(),
      persist_debounce_ms: persist_debounce_ms
    }

    # Try to load from DB, fall back to provided data
    state = maybe_load_from_db(state)

    # Update registry metadata with actual token count
    update_registry_tokens(state)

    # Only schedule persist if started with non-empty messages
    state =
      if messages != [] do
        schedule_persist(%{state | dirty: true})
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:store, messages, metadata}, _from, state) do
    merged_metadata = Map.merge(state.metadata, metadata)
    all_messages = state.messages ++ messages
    token_count = estimate_tokens(all_messages)

    state = %{state |
      messages: all_messages,
      metadata: merged_metadata,
      token_count: token_count,
      dirty: true
    }

    update_registry_tokens(state)
    state = schedule_persist(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:flush_persist, _from, state) do
    state =
      if state.persist_ref do
        Process.cancel_timer(state.persist_ref)
        %{state | persist_ref: nil}
      else
        state
      end

    state =
      if state.dirty do
        case do_persist(state) do
          {:ok, _} -> %{state | dirty: false}
          {:error, _} = err -> raise "flush_persist failed: #{inspect(err)}"
        end
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:retrieve_all, _from, state) do
    {:reply, {:ok, state.messages}, state}
  end

  @impl true
  def handle_call({:retrieve, query}, _from, state) do
    result =
      if state.token_count < @keyword_match_budget do
        state.messages
      else
        keyword_match(state.messages, query)
      end

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:smart_retrieve, question}, _from, state) do
    context = format_messages_as_context(state.messages)

    model = Loom.Teams.ModelRouter.default_model()

    messages = [
      ReqLLM.Context.system("""
      You are a context retrieval assistant. Answer the question using ONLY
      the conversation context provided. Be specific and concise. If the
      context doesn't contain the answer, say so.
      """),
      ReqLLM.Context.user("Context:\n#{context}\n\nQuestion: #{question}")
    ]

    case call_llm(model, messages) do
      {:ok, response} ->
        answer = extract_answer(response)
        maybe_track_cost(state, response)
        {:reply, {:ok, answer}, state}

      {:error, _reason} ->
        # Fallback: format matching messages as text so the return type
        # is always a binary string, not a raw message list.
        result = keyword_fallback(state, question) |> format_messages_as_context()
        {:reply, {:ok, result}, state}
    end
  end

  @impl true
  def handle_call(:index_entry, _from, state) do
    entry = "[Keeper:#{state.id}] topic=#{state.topic} source=#{state.source_agent} tokens=#{state.token_count}"
    {:reply, entry, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_info(:persist, state) do
    state = %{state | persist_ref: nil}

    state =
      if state.dirty do
        try do
          case do_persist(state) do
            {:ok, _} ->
              %{state | dirty: false}

            {:error, reason} ->
              Logger.warning("[ContextKeeper:#{state.id}] Persist failed: #{inspect(reason)}, will retry")
              schedule_persist(state)
          end
        rescue
          e ->
            Logger.warning("[ContextKeeper:#{state.id}] Persist raised: #{Exception.message(e)}, will retry")
            schedule_persist(state)
        end
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.persist_ref, do: Process.cancel_timer(state.persist_ref)

    if state.dirty do
      try do
        case do_persist(state) do
          {:ok, _} -> :ok
          {:error, reason} ->
            Logger.error("[ContextKeeper:#{state.id}] Final persist failed on terminate: #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.error("[ContextKeeper:#{state.id}] Final persist raised on terminate: #{Exception.message(e)}")
      end
    end

    :ok
  end

  # --- Private ---

  defp maybe_load_from_db(state) do
    case Repo.get(KeeperSchema, state.id) do
      %KeeperSchema{} = record ->
        messages = restore_messages(record.messages)
        token_count = record.token_count || estimate_tokens(messages)

        %{
          state
          | messages: messages,
            token_count: token_count,
            metadata: record.metadata || %{},
            topic: record.topic,
            source_agent: record.source_agent
        }

      nil ->
        state
    end
  rescue
    e in DBConnection.OwnershipError ->
      Logger.debug("[ContextKeeper:#{state.id}] DB not available during init: #{inspect(e.__struct__)}")
      state
  end

  defp restore_messages(nil), do: []
  defp restore_messages(messages) when is_list(messages), do: messages
  defp restore_messages(%{"messages" => messages}) when is_list(messages), do: messages
  defp restore_messages(_), do: []

  defp schedule_persist(%{persist_ref: ref} = state) when is_reference(ref) do
    state
  end

  defp schedule_persist(state) do
    ref = Process.send_after(self(), :persist, state.persist_debounce_ms)
    %{state | persist_ref: ref}
  end

  defp do_persist(state) do
    attrs = %{
      id: state.id,
      team_id: state.team_id,
      topic: state.topic,
      source_agent: state.source_agent,
      messages: %{"messages" => state.messages},
      token_count: state.token_count,
      metadata: state.metadata,
      status: :active
    }

    %KeeperSchema{id: state.id}
    |> KeeperSchema.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id]},
      conflict_target: :id
    )
  end

  defp update_registry_tokens(state) do
    Registry.update_value(
      Loom.Teams.AgentRegistry,
      {state.team_id, "keeper:#{state.id}"},
      fn _old -> %{type: :keeper, topic: state.topic, tokens: state.token_count, source_agent: state.source_agent} end
    )
  rescue
    _ -> :ok
  end

  defp keyword_match(messages, query) do
    words =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> MapSet.new()

    scored =
      messages
      |> Enum.map(fn msg ->
        content = message_content(msg) |> String.downcase()
        msg_words = String.split(content, ~r/\s+/, trim: true) |> MapSet.new()
        overlap = MapSet.intersection(words, msg_words) |> MapSet.size()
        {msg, overlap}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    # Take top messages up to budget
    {result, _tokens} =
      Enum.reduce_while(scored, {[], 0}, fn {msg, _score}, {acc, used} ->
        msg_tokens = estimate_tokens_for_message(msg)

        if used + msg_tokens <= @keyword_match_budget do
          {:cont, {acc ++ [msg], used + msg_tokens}}
        else
          {:halt, {acc, used}}
        end
      end)

    result
  end

  defp format_messages_as_context(messages) do
    messages
    |> Enum.map(fn msg ->
      role = msg[:role] || msg["role"] || "unknown"
      content = message_content(msg)
      "[#{role}]: #{content}"
    end)
    |> Enum.join("\n")
  end

  defp call_llm(model, messages) do
    ReqLLM.generate_text(model, messages, [])
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp extract_answer(response) do
    classified = ReqLLM.Response.classify(response)
    classified.text || ""
  end

  defp maybe_track_cost(state, response) do
    if state.team_id do
      case ReqLLM.Response.usage(response) do
        %{} = usage ->
          Loom.Teams.CostTracker.record_usage(state.team_id, "keeper:#{state.id}", %{
            input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
            output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0
          })

        _ ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp keyword_fallback(state, query) do
    if state.token_count < @keyword_match_budget do
      state.messages
    else
      keyword_match(state.messages, query)
    end
  end

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(%{"content" => content}) when is_binary(content), do: content
  defp message_content(_), do: ""

  defp estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&estimate_tokens_for_message/1)
    |> Enum.sum()
  end

  defp estimate_tokens(_), do: 0

  defp estimate_tokens_for_message(msg) do
    content = message_content(msg)
    div(String.length(content), @chars_per_token) + 4
  end
end
