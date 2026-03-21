defmodule Loomkin.Teams.ContextKeeper do
  @moduledoc """
  GenServer that holds conversation context for a team.

  Supports both raw retrieval (keyword matching) and smart retrieval
  (single LLM call to answer questions about stored context).

  Registered in Loomkin.Keepers.Registry as `{team_id, keeper_id}` with
  metadata `%{type: :keeper, topic: topic, tokens: count}`.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Loomkin.Repo
  alias Loomkin.Schemas.ContextKeeper, as: KeeperSchema
  alias Loomkin.Telemetry, as: LoomkinTelemetry

  @chars_per_token 4
  @keyword_match_budget 10_000
  @persist_debounce_ms 50
  @staleness_sweep_ms :timer.minutes(30)
  @archive_staleness_threshold 75
  @archive_min_age_days 7
  @summary_token_threshold 5_000

  defstruct [
    :id,
    :team_id,
    :topic,
    :source_agent,
    :created_at,
    :last_accessed_at,
    :last_agent_name,
    :summary,
    messages: [],
    token_count: 0,
    metadata: %{},
    access_count: 0,
    retrieval_mode_histogram: %{},
    relevance_score: 0.0,
    confidence: 0.5,
    success_count: 0,
    miss_count: 0,
    dirty: false,
    persist_ref: nil,
    persist_debounce_ms: @persist_debounce_ms
  ]

  # --- Public API ---

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:id]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    team_id = Keyword.fetch!(opts, :team_id)
    topic = Keyword.get(opts, :topic, "unnamed")
    source_agent = Keyword.get(opts, :source_agent, "unknown")

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {Loomkin.Keepers.Registry, {team_id, id},
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

  @doc "Record an access event on this keeper (called by retrieval tools)."
  def record_access(pid, agent_name, mode) do
    GenServer.cast(pid, {:record_access, agent_name, mode})
  end

  @doc "Get full state for debugging."
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc false
  def flush_persist(pid) do
    GenServer.call(pid, :flush_persist)
  end

  @doc """
  Compute staleness score for a keeper state (0-100).

  Four-factor model:
  - Time decay: 5 pts/hour since creation (capped at 25)
  - Access decay: accumulates when unused (12h no access = 25 pts)
  - Relevance decay: inverse of relevance_score (0-25)
  - Confidence decay: based on success/miss ratio (0-25)
  """
  def compute_staleness(state) when is_map(state) do
    now = DateTime.utc_now()

    time_decay = compute_time_decay(state[:created_at] || now, now)
    access_decay = compute_access_decay(state[:last_accessed_at], now)
    relevance_decay = compute_relevance_decay(state[:relevance_score] || 0.0)

    confidence_decay =
      compute_confidence_decay(state[:success_count] || 0, state[:miss_count] || 0)

    min(time_decay + access_decay + relevance_decay + confidence_decay, 100)
  end

  @doc "Return staleness state atom based on score."
  def staleness_state(score) when is_number(score) do
    cond do
      score < 25 -> :fresh
      score < 50 -> :warm
      score < 75 -> :stale
      true -> :expired
    end
  end

  @doc "Get staleness score for a running keeper."
  def get_staleness(pid) do
    GenServer.call(pid, :get_staleness)
  end

  @rehydrate_limit 50

  @doc "Rehydrate keepers for a team from the database (most recent first, capped at #{@rehydrate_limit})."
  def rehydrate_from_db(team_id) do
    keepers =
      Loomkin.Schemas.ContextKeeper
      |> where([k], k.team_id == ^team_id and k.status == :active)
      |> order_by([k], desc: k.inserted_at)
      |> limit(@rehydrate_limit)
      |> Repo.all()

    Enum.each(keepers, fn record ->
      # Skip if already running
      case Registry.lookup(Loomkin.Keepers.Registry, {team_id, record.id}) do
        [{_pid, _}] ->
          :ok

        [] ->
          opts = [
            id: record.id,
            team_id: team_id,
            topic: record.topic,
            source_agent: record.source_agent
          ]

          DynamicSupervisor.start_child(
            Loomkin.Teams.AgentSupervisor,
            {__MODULE__, opts}
          )
      end
    end)
  rescue
    e ->
      Logger.warning(
        "[ContextKeeper] rehydrate_from_db failed team=#{team_id} error=#{inspect(e)}"
      )

      :ok
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

    schedule_staleness_sweep()

    if state.token_count >= @summary_token_threshold and is_nil(state.summary) do
      send(self(), :generate_summary)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:store, messages, metadata}, _from, state) do
    merged_metadata = Map.merge(state.metadata, metadata)
    all_messages = messages ++ state.messages
    token_count = estimate_tokens(all_messages)
    was_below = state.token_count < @summary_token_threshold

    state = %{
      state
      | messages: all_messages,
        metadata: merged_metadata,
        token_count: token_count,
        dirty: true
    }

    update_registry_tokens(state)
    state = schedule_persist(state)

    if was_below and token_count >= @summary_token_threshold and is_nil(state.summary) do
      send(self(), :generate_summary)
    end

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

    if state.dirty do
      case do_persist(state) do
        {:ok, _} ->
          {:reply, :ok, %{state | dirty: false}}

        {:error, _reason} = err ->
          Logger.warning("[ContextKeeper] flush_persist failed: #{inspect(err)}")
          {:reply, err, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:retrieve_all, _from, state) do
    {:reply, {:ok, Enum.reverse(state.messages)}, state}
  end

  @impl true
  def handle_call({:retrieve, query}, _from, state) do
    result =
      if state.token_count < @keyword_match_budget do
        Enum.reverse(state.messages)
      else
        keyword_match(Enum.reverse(state.messages), query)
      end

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:smart_retrieve, question}, _from, state) do
    context = state.messages |> Enum.reverse() |> format_messages_as_context()

    model = Loomkin.Teams.ModelRouter.default_model()

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
    entry =
      "[Keeper:#{state.id}] topic=#{state.topic} source=#{state.source_agent} tokens=#{state.token_count}"

    {:reply, entry, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_call(:get_staleness, _from, state) do
    score = compute_staleness(Map.from_struct(state))
    {:reply, %{score: score, state: staleness_state(score)}, state}
  end

  @impl true
  def handle_cast({:record_access, agent_name, mode}, state) do
    mode_key = to_string(mode)

    histogram =
      Map.update(state.retrieval_mode_histogram, mode_key, 1, &(&1 + 1))

    state = %{
      state
      | access_count: state.access_count + 1,
        last_accessed_at: DateTime.utc_now(),
        last_agent_name: agent_name,
        retrieval_mode_histogram: histogram,
        dirty: true
    }

    state = schedule_persist(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_summary, summary}, state) do
    state = %{state | summary: summary, dirty: true}
    state = schedule_persist(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:generate_summary, state) do
    pid = self()

    Task.Supervisor.start_child(Loomkin.Healing.TaskSupervisor, fn ->
      summary = state.messages |> Enum.reverse() |> generate_summary_text()

      if summary do
        GenServer.cast(pid, {:set_summary, summary})
      end
    end)

    {:noreply, state}
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

            {:error, _reason} ->
              schedule_persist(state)
          end
        rescue
          e ->
            Logger.debug("[ContextKeeper] persist failed: #{Exception.message(e)}")
            schedule_persist(state)
        end
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:staleness_sweep, state) do
    score = compute_staleness(Map.from_struct(state))
    age_days = DateTime.diff(DateTime.utc_now(), state.created_at, :day)

    if score >= @archive_staleness_threshold and age_days >= @archive_min_age_days do
      do_archive(state)
      # Set dirty: false so terminate/2 doesn't overwrite archived status with :active
      {:stop, :normal, %{state | dirty: false}}
    else
      schedule_staleness_sweep()
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.persist_ref, do: Process.cancel_timer(state.persist_ref)

    if state.dirty do
      try do
        case do_persist(state) do
          {:ok, _} ->
            :ok

          {:error, _reason} ->
            :ok
        end
      rescue
        e ->
          Logger.debug("[ContextKeeper] terminate persist failed: #{Exception.message(e)}")
          :ok
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
            source_agent: record.source_agent,
            last_accessed_at: record.last_accessed_at,
            access_count: record.access_count || 0,
            last_agent_name: record.last_agent_name,
            retrieval_mode_histogram: record.retrieval_mode_histogram || %{},
            summary: record.summary,
            relevance_score: record.relevance_score || 0.0,
            confidence: record.confidence || 0.5,
            success_count: record.success_count || 0,
            miss_count: record.miss_count || 0
        }

      nil ->
        state
    end
  rescue
    _e in DBConnection.OwnershipError ->
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

  defp schedule_staleness_sweep do
    Process.send_after(self(), :staleness_sweep, @staleness_sweep_ms)
  end

  defp compute_time_decay(created_at, now) do
    hours = DateTime.diff(now, created_at, :second) / 3600.0
    min(round(hours * 5), 25)
  end

  defp compute_access_decay(nil, _now), do: 25

  defp compute_access_decay(last_accessed_at, now) do
    hours_since_access = DateTime.diff(now, last_accessed_at, :second) / 3600.0
    min(round(hours_since_access / 12.0 * 25), 25)
  end

  defp compute_relevance_decay(relevance_score) do
    round((1.0 - min(relevance_score, 1.0)) * 25)
  end

  defp compute_confidence_decay(success_count, miss_count) do
    total = success_count + miss_count

    if total == 0 do
      13
    else
      miss_ratio = miss_count / total
      round(miss_ratio * 25)
    end
  end

  defp generate_summary_text(messages) do
    context = format_messages_as_context(messages) |> String.slice(0, 8000)
    model = Loomkin.Teams.ModelRouter.select(:grunt)

    llm_messages = [
      ReqLLM.Context.system(
        "Summarize the following conversation context in 100 words or fewer. " <>
          "Focus on key decisions, outcomes, and topics discussed. Be specific and concise."
      ),
      ReqLLM.Context.user(context)
    ]

    case call_llm(model, llm_messages) do
      {:ok, response} ->
        extract_answer(response) |> String.slice(0, 500)

      {:error, _} ->
        nil
    end
  rescue
    e ->
      Logger.debug("[ContextKeeper] generate_summary_text failed: #{Exception.message(e)}")
      nil
  end

  defp do_archive(state) do
    KeeperSchema
    |> where([k], k.id == ^state.id)
    |> Repo.update_all(set: [status: "archived"])
  rescue
    e ->
      Logger.debug("[ContextKeeper] do_archive failed: #{Exception.message(e)}")
      :ok
  end

  defp do_persist(state) do
    attrs = %{
      id: state.id,
      team_id: state.team_id,
      topic: state.topic,
      source_agent: state.source_agent,
      messages: %{"messages" => Enum.reverse(state.messages)},
      token_count: state.token_count,
      metadata: state.metadata,
      status: :active,
      last_accessed_at: state.last_accessed_at,
      access_count: state.access_count,
      last_agent_name: state.last_agent_name,
      retrieval_mode_histogram: state.retrieval_mode_histogram,
      summary: state.summary,
      relevance_score: state.relevance_score,
      confidence: state.confidence,
      success_count: state.success_count,
      miss_count: state.miss_count
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
      Loomkin.Keepers.Registry,
      {state.team_id, state.id},
      fn _old ->
        %{
          type: :keeper,
          topic: state.topic,
          tokens: state.token_count,
          source_agent: state.source_agent
        }
      end
    )
  rescue
    e ->
      Logger.debug("[ContextKeeper] update_registry_tokens failed: #{Exception.message(e)}")
      :ok
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
    meta = %{model: model, caller: __MODULE__, function: :call_llm}

    LoomkinTelemetry.span_llm_request(meta, fn ->
      Loomkin.LLM.generate_text(model, messages, [])
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp extract_answer(response) do
    classified = ReqLLM.Response.classify(response)
    classified.text
  end

  defp maybe_track_cost(state, response) do
    if state.team_id do
      case ReqLLM.Response.usage(response) do
        %{} = usage ->
          Loomkin.Teams.CostTracker.record_usage(state.team_id, "keeper:#{state.id}", %{
            input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
            output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0
          })

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.debug("[ContextKeeper] maybe_track_cost failed: #{Exception.message(e)}")
      :ok
  end

  defp keyword_fallback(state, query) do
    if state.token_count < @keyword_match_budget do
      Enum.reverse(state.messages)
    else
      keyword_match(Enum.reverse(state.messages), query)
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
