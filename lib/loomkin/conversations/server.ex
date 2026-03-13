defmodule Loomkin.Conversations.Server do
  @moduledoc """
  GenServer managing a single conversation session — shared message history,
  turn order, round tracking, and termination conditions.

  The ConversationServer is the authoritative owner of the conversation's
  shared history. Conversation agents read from and write to this single
  ordered message log.
  """

  use GenServer

  alias Loomkin.Conversations.TurnStrategy
  alias Loomkin.Signals

  @inactivity_timeout_ms 60_000

  defstruct [
    :id,
    :team_id,
    :topic,
    :context,
    :spawned_by,
    :turn_strategy,
    :strategy_module,
    :current_speaker,
    :max_tokens,
    :started_at,
    :ended_at,
    :summary,
    participants: [],
    history: [],
    current_round: 1,
    max_rounds: 10,
    tokens_used: 0,
    status: :active,
    yields_this_round: MapSet.new(),
    inactivity_timer: nil
  ]

  # --- Public API ---

  @doc "Start a conversation server."
  def start_link(opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())

    GenServer.start_link(__MODULE__, Keyword.put(opts, :id, id),
      name: {:via, Registry, {Loomkin.Conversations.Registry, id}}
    )
  end

  @doc "Submit speech for the current turn."
  def speak(conversation_id, agent_name, content, opts \\ []) do
    call(conversation_id, {:speak, agent_name, content, opts})
  end

  @doc "Yield the current turn (nothing to add)."
  def yield(conversation_id, agent_name, reason \\ nil) do
    call(conversation_id, {:yield, agent_name, reason})
  end

  @doc "Submit a short reaction."
  def react(conversation_id, agent_name, type, brief) do
    call(conversation_id, {:react, agent_name, type, brief})
  end

  @doc "Get current conversation context for prompting the next speaker."
  def get_context(conversation_id) do
    call(conversation_id, :get_context)
  end

  @doc "Get conversation state."
  def get_state(conversation_id) do
    call(conversation_id, :get_state)
  end

  @doc "Force-end the conversation."
  def terminate_conversation(conversation_id, reason) do
    call(conversation_id, {:terminate, reason})
  end

  @doc "Attach a summary (called by the weaver)."
  def attach_summary(conversation_id, summary) do
    call(conversation_id, {:attach_summary, summary})
  end

  defp call(conversation_id, message) do
    case Registry.lookup(Loomkin.Conversations.Registry, conversation_id) do
      [{pid, _}] -> GenServer.call(pid, message, 30_000)
      [] -> {:error, :conversation_not_found}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    team_id = Keyword.fetch!(opts, :team_id)
    topic = Keyword.fetch!(opts, :topic)
    participants = Keyword.fetch!(opts, :participants)
    strategy = Keyword.get(opts, :turn_strategy, :round_robin)

    state = %__MODULE__{
      id: id,
      team_id: team_id,
      topic: topic,
      context: Keyword.get(opts, :context),
      spawned_by: Keyword.get(opts, :spawned_by),
      turn_strategy: strategy,
      strategy_module: TurnStrategy.module_for(strategy),
      participants: participants,
      max_rounds: Keyword.get(opts, :max_rounds, 10),
      max_tokens: Keyword.get(opts, :max_tokens),
      started_at: DateTime.utc_now()
    }

    emit_started(state)

    {:ok, state, {:continue, :advance_turn}}
  end

  @impl true
  def handle_continue(:advance_turn, %{status: :active} = state) do
    state = reset_inactivity_timer(state)

    next =
      state.strategy_module.next_speaker(state.participants, state.history, state.current_round)

    state = %{state | current_speaker: next}

    # Signal the next agent that it's their turn
    notify_agent_turn(state, next)

    {:noreply, state}
  end

  def handle_continue(:advance_turn, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:speak, agent_name, content, opts}, _from, state) do
    if state.status != :active do
      {:reply, {:error, :conversation_not_active}, state}
    else
      tokens = Keyword.get(opts, :tokens, estimate_tokens(content))

      entry = %{
        speaker: agent_name,
        content: content,
        round: state.current_round,
        type: :speech,
        timestamp: DateTime.utc_now()
      }

      state =
        state
        |> append_entry(entry)
        |> add_tokens(tokens)

      emit_turn(state, entry)

      state = maybe_advance_round(state)
      state = check_termination(state)

      if state.status == :active do
        {:reply, :ok, state, {:continue, :advance_turn}}
      else
        {:reply, :ok, state}
      end
    end
  end

  def handle_call({:yield, agent_name, reason}, _from, state) do
    if state.status != :active do
      {:reply, {:error, :conversation_not_active}, state}
    else
      entry = %{
        speaker: agent_name,
        content: reason || "yielded",
        round: state.current_round,
        type: :yield,
        timestamp: DateTime.utc_now()
      }

      state =
        state
        |> append_entry(entry)
        |> Map.update!(:yields_this_round, &MapSet.put(&1, agent_name))

      emit_yield(state, agent_name, reason)

      # Check all-yield termination before advancing the round,
      # because round advance clears yields_this_round.
      state = check_termination(state)
      state = if state.status == :active, do: maybe_advance_round(state), else: state
      state = check_termination(state)

      if state.status == :active do
        {:reply, :ok, state, {:continue, :advance_turn}}
      else
        {:reply, :ok, state}
      end
    end
  end

  def handle_call({:react, agent_name, type, brief}, _from, state) do
    if state.status != :active do
      {:reply, {:error, :conversation_not_active}, state}
    else
      entry = %{
        speaker: agent_name,
        content: brief,
        round: state.current_round,
        type: {:reaction, type},
        timestamp: DateTime.utc_now()
      }

      state = append_entry(state, entry)
      emit_turn(state, entry)

      {:reply, :ok, state}
    end
  end

  def handle_call(:get_context, _from, state) do
    context = %{
      id: state.id,
      topic: state.topic,
      history: state.history,
      current_round: state.current_round,
      current_speaker: state.current_speaker,
      participants: Enum.map(state.participants, & &1.name),
      tokens_used: state.tokens_used,
      max_tokens: state.max_tokens,
      max_rounds: state.max_rounds,
      status: state.status
    }

    {:reply, {:ok, context}, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call({:terminate, reason}, _from, state) do
    state = end_conversation(state, reason)
    {:reply, :ok, state}
  end

  def handle_call({:attach_summary, summary}, _from, state) do
    state = %{state | summary: summary, status: :completed}
    emit_ended(state, :summary_complete)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:inactivity_timeout, state) do
    if state.status == :active do
      state = end_conversation(state, :inactivity_timeout)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private Helpers ---

  defp append_entry(state, entry) do
    %{state | history: state.history ++ [entry]}
  end

  defp add_tokens(state, tokens) do
    %{state | tokens_used: state.tokens_used + tokens}
  end

  defp estimate_tokens(content) when is_binary(content) do
    # Rough estimate: 1 token ~ 4 characters
    div(byte_size(content), 4) + 1
  end

  defp maybe_advance_round(state) do
    if state.strategy_module.should_advance_round?(
         state.participants,
         state.history,
         state.current_round
       ) do
      emit_round_complete(state)

      %{state | current_round: state.current_round + 1, yields_this_round: MapSet.new()}
    else
      state
    end
  end

  defp check_termination(state) do
    cond do
      state.current_round > state.max_rounds ->
        end_conversation(state, :max_rounds)

      state.max_tokens && state.tokens_used >= state.max_tokens ->
        end_conversation(state, :max_tokens)

      all_yielded?(state) ->
        end_conversation(state, :all_yielded)

      true ->
        state
    end
  end

  defp all_yielded?(state) do
    participant_names = state.participants |> Enum.map(& &1.name) |> MapSet.new()
    MapSet.equal?(state.yields_this_round, participant_names)
  end

  defp end_conversation(state, reason) do
    cancel_inactivity_timer(state)

    state = %{
      state
      | status: :summarizing,
        ended_at: DateTime.utc_now()
    }

    emit_ended(state, reason)

    # Notify weaver (via PubSub) that summarization should begin
    notify_summarize(state)

    state
  end

  defp reset_inactivity_timer(state) do
    cancel_inactivity_timer(state)
    timer = Process.send_after(self(), :inactivity_timeout, @inactivity_timeout_ms)
    %{state | inactivity_timer: timer}
  end

  defp cancel_inactivity_timer(%{inactivity_timer: nil}), do: :ok
  defp cancel_inactivity_timer(%{inactivity_timer: ref}), do: Process.cancel_timer(ref)

  # --- Signal Emission ---

  defp emit_started(state) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationStarted.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        topic: state.topic,
        participants: Enum.map(state.participants, & &1.name),
        strategy: to_string(state.turn_strategy)
      })
    )
  end

  defp emit_turn(state, entry) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationTurn.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        speaker: entry.speaker,
        content: entry.content,
        round: state.current_round
      })
    )
  end

  defp emit_yield(state, agent_name, reason) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationYield.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        agent_name: agent_name,
        reason: reason || ""
      })
    )
  end

  defp emit_round_complete(state) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationRoundComplete.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        round: state.current_round
      })
    )
  end

  defp emit_ended(state, reason) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationEnded.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        reason: to_string(reason),
        rounds: state.current_round,
        tokens_used: state.tokens_used
      })
    )
  end

  defp notify_agent_turn(state, agent_name) do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "conversation:#{state.id}",
      {:your_turn, state.id, state.history, state.topic, state.context, agent_name}
    )
  end

  defp notify_summarize(state) do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "conversation:#{state.id}",
      {:summarize, state.id, state.history, state.topic, state.participants}
    )
  end
end
