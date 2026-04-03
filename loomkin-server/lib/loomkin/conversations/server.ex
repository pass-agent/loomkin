defmodule Loomkin.Conversations.Server do
  @moduledoc """
  GenServer managing a single conversation session — shared message history,
  turn order, round tracking, and termination conditions.

  The ConversationServer is the authoritative owner of the conversation's
  shared history. Conversation agents read from and write to this single
  ordered message log.
  """

  use GenServer

  require Logger

  alias Loomkin.Conversations.TurnStrategy
  alias Loomkin.Repo
  alias Loomkin.Schemas.Conversation, as: ConversationSchema
  alias Loomkin.Signals

  @default_inactivity_timeout_ms 60_000
  @budget_warning_pct 0.8

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
    :end_reason,
    :summary,
    participants: [],
    history: [],
    current_round: 1,
    max_rounds: 10,
    tokens_used: 0,
    status: :active,
    yields_this_round: MapSet.new(),
    inactivity_timer: nil,
    budget_warned: false
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

  @doc "Signal that all agents are ready — kicks off the first turn."
  def begin(conversation_id) do
    call(conversation_id, :begin)
  end

  @doc "Force-end the conversation."
  def terminate_conversation(conversation_id, reason) do
    call(conversation_id, {:terminate, reason})
  end

  @doc "Attach a summary (called by the weaver). Caller must include agent_name in context."
  def attach_summary(conversation_id, summary) do
    call(conversation_id, {:attach_summary, summary})
  end

  defp call(conversation_id, message) do
    case Registry.lookup(Loomkin.Conversations.Registry, conversation_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, message, 30_000)
        catch
          :exit, {:noproc, _} -> {:error, :conversation_not_found}
          :exit, {:normal, _} -> {:error, :conversation_not_found}
        end

      [] ->
        {:error, :conversation_not_found}
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
    persist_conversation(state)

    {:ok, state}
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

  # --- Begin ---

  @impl true
  def handle_call(:begin, _from, %{status: :active} = state) do
    {:reply, :ok, state, {:continue, :advance_turn}}
  end

  def handle_call(:begin, _from, state) do
    {:reply, {:error, :conversation_not_active}, state}
  end

  # --- Speak ---

  def handle_call({:speak, _, _, _}, _from, %{status: status} = state) when status != :active do
    {:reply, {:error, :conversation_not_active}, state}
  end

  def handle_call({:speak, agent_name, content, opts}, _from, state) do
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

    state = advance_and_check(state)

    if state.status == :active do
      {:reply, :ok, state, {:continue, :advance_turn}}
    else
      {:reply, :ok, state}
    end
  end

  # --- Yield ---

  def handle_call({:yield, _, _}, _from, %{status: status} = state) when status != :active do
    {:reply, {:error, :conversation_not_active}, state}
  end

  def handle_call({:yield, agent_name, reason}, _from, state) do
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
    # Then advance and check again (for max_rounds).
    state = advance_and_check(state)

    if state.status == :active do
      {:reply, :ok, state, {:continue, :advance_turn}}
    else
      {:reply, :ok, state}
    end
  end

  # --- React ---

  def handle_call({:react, _, _, _}, _from, %{status: status} = state) when status != :active do
    {:reply, {:error, :conversation_not_active}, state}
  end

  def handle_call({:react, agent_name, type, brief}, _from, state) do
    entry = %{
      speaker: agent_name,
      content: brief,
      round: state.current_round,
      type: {:reaction, type},
      timestamp: DateTime.utc_now()
    }

    state = append_entry(state, entry)
    emit_reaction(state, agent_name, type, brief)

    {:reply, :ok, state}
  end

  # --- Query ---

  def handle_call(:get_context, _from, state) do
    context = %{
      id: state.id,
      topic: state.topic,
      history: Enum.reverse(state.history),
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

  # --- Terminate ---

  def handle_call({:terminate, _reason}, _from, %{status: status} = state)
      when status != :active do
    {:reply, {:error, :conversation_not_active}, state}
  end

  def handle_call({:terminate, reason}, _from, state) do
    state = end_conversation(state, reason)
    {:reply, :ok, state}
  end

  # --- Attach Summary ---

  def handle_call({:attach_summary, summary}, _from, state) do
    state = %{state | summary: summary, status: :completed}
    emit_ended(state)
    persist_conversation(state)

    # Server's work is done — reply and stop
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:inactivity_timeout, %{status: :active} = state) do
    {:noreply, end_conversation(state, :inactivity_timeout)}
  end

  def handle_info(:inactivity_timeout, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private Helpers ---

  defp append_entry(state, entry) do
    %{state | history: [entry | state.history]}
  end

  defp add_tokens(state, tokens) do
    state = %{state | tokens_used: state.tokens_used + tokens}
    maybe_emit_budget_warning(state)
  end

  defp estimate_tokens(content) when is_binary(content) do
    # Rough estimate: 1 token ~ 4 characters
    div(byte_size(content), 4) + 1
  end

  defp maybe_emit_budget_warning(%{budget_warned: true} = state), do: state
  defp maybe_emit_budget_warning(%{max_tokens: nil} = state), do: state

  defp maybe_emit_budget_warning(state) do
    if state.tokens_used >= state.max_tokens * @budget_warning_pct do
      emit_budget_warning(state)
      %{state | budget_warned: true}
    else
      state
    end
  end

  defp advance_and_check(state) do
    state = check_termination(state)
    state = if state.status == :active, do: maybe_advance_round(state), else: state
    if state.status == :active, do: check_termination(state), else: state
  end

  defp maybe_advance_round(state) do
    if state.strategy_module.should_advance_round?(
         state.participants,
         state.history,
         state.current_round
       ) do
      emit_round_complete(state)
      new_round = state.current_round + 1
      emit_round_started(state, new_round)

      %{state | current_round: new_round, yields_this_round: MapSet.new()}
    else
      state
    end
  end

  defp check_termination(%{status: status} = state) when status != :active, do: state

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
        ended_at: DateTime.utc_now(),
        end_reason: reason,
        inactivity_timer: nil
    }

    emit_summarizing(state, reason)
    persist_conversation(state)

    # Notify weaver (via PubSub) that summarization should begin
    notify_summarize(state)

    state
  end

  defp reset_inactivity_timer(state) do
    cancel_inactivity_timer(state)
    timer = Process.send_after(self(), :inactivity_timeout, inactivity_timeout_ms())
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

  defp emit_reaction(state, agent_name, type, brief) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationReaction.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        agent_name: agent_name,
        reaction_type: to_string(type),
        brief: brief
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

  defp emit_round_started(state, round) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationRoundStarted.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        round: round
      })
    )
  end

  defp emit_summarizing(state, reason) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationSummarizing.new!(%{
        conversation_id: state.id,
        team_id: state.team_id
      })
    )

    # Also emit the reason as a terminated signal for observability
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationTerminated.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        reason: format_reason(reason)
      })
    )
  end

  defp emit_ended(state) do
    participant_names = Enum.map(state.participants, & &1.name)

    base = %{
      conversation_id: state.id,
      team_id: state.team_id,
      reason: format_reason(state.end_reason || :summary_complete),
      rounds: state.current_round,
      tokens_used: state.tokens_used,
      participants: participant_names,
      summary: state.summary
    }

    signal_data =
      if state.spawned_by do
        Map.put(base, :spawned_by, state.spawned_by)
      else
        base
      end

    Signals.publish(Loomkin.Signals.Collaboration.ConversationEnded.new!(signal_data))
  end

  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp emit_budget_warning(state) do
    Signals.publish(
      Loomkin.Signals.Collaboration.ConversationBudgetWarning.new!(%{
        conversation_id: state.id,
        team_id: state.team_id,
        tokens_used: state.tokens_used,
        max_tokens: state.max_tokens
      })
    )
  end

  defp notify_agent_turn(state, agent_name) do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "conversation:#{state.id}",
      {:your_turn, state.id, Enum.reverse(state.history), state.topic, state.context, agent_name}
    )
  end

  defp notify_summarize(state) do
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "conversation:#{state.id}",
      {:summarize, state.id, Enum.reverse(state.history), state.topic, state.participants}
    )
  end

  defp inactivity_timeout_ms do
    Loomkin.Config.get(:conversations, :inactivity_timeout_ms) || @default_inactivity_timeout_ms
  end

  defp persist_conversation(state) do
    attrs = %{
      id: state.id,
      team_id: state.team_id,
      topic: state.topic,
      context: state.context,
      spawned_by: state.spawned_by,
      turn_strategy: to_string(state.turn_strategy || "round_robin"),
      status: to_string(state.status),
      end_reason: if(state.end_reason, do: to_string(state.end_reason)),
      current_round: state.current_round,
      max_rounds: state.max_rounds,
      tokens_used: state.tokens_used,
      max_tokens: state.max_tokens,
      participants: serialize_participants(state.participants),
      history: serialize_history(state.history),
      summary: state.summary,
      started_at: state.started_at,
      ended_at: state.ended_at
    }

    %ConversationSchema{id: state.id}
    |> ConversationSchema.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  rescue
    e ->
      Logger.warning(
        "[Conversation.Server] persist failed for #{state.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp serialize_participants(participants) do
    Enum.map(participants, fn
      %{name: name} = p ->
        %{
          "name" => name,
          "perspective" => Map.get(p, :perspective, ""),
          "expertise" => Map.get(p, :expertise, "")
        }

      name when is_binary(name) ->
        %{"name" => name}

      other ->
        %{"name" => inspect(other)}
    end)
  end

  defp serialize_history(history) do
    history
    |> Enum.reverse()
    |> Enum.map(fn entry ->
      %{
        "speaker" => entry.speaker,
        "content" => entry.content,
        "round" => entry.round,
        "type" => serialize_type(entry.type),
        "timestamp" => DateTime.to_iso8601(entry.timestamp)
      }
    end)
  end

  defp serialize_type(:speech), do: "speech"
  defp serialize_type(:yield), do: "yield"
  defp serialize_type({:reaction, type}), do: "reaction:#{type}"
  defp serialize_type(other), do: to_string(other)
end
