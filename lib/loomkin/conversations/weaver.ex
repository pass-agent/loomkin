defmodule Loomkin.Conversations.Weaver do
  @moduledoc """
  Observer agent that watches a conversation and produces a structured summary
  when it ends. Does NOT participate in turns.

  The weaver subscribes to conversation PubSub, observes all turns, and when
  the conversation transitions to :summarizing, generates a summary via LLM
  and attaches it to the ConversationServer.
  """

  use GenServer

  require Logger

  alias Loomkin.Conversations.Server

  defstruct [
    :conversation_id,
    :team_id,
    :model,
    :spawned_by,
    :task_ref
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    team_id = Keyword.fetch!(opts, :team_id)
    model = Keyword.fetch!(opts, :model)

    Phoenix.PubSub.subscribe(Loomkin.PubSub, "conversation:#{conversation_id}")

    state = %__MODULE__{
      conversation_id: conversation_id,
      team_id: team_id,
      model: model,
      spawned_by: Keyword.get(opts, :spawned_by)
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:summarize, conversation_id, history, topic, participants}, state) do
    if conversation_id == state.conversation_id do
      # Dispatch summary generation to a Task to avoid blocking the mailbox
      task =
        Task.Supervisor.async_nolink(Loomkin.Healing.TaskSupervisor, fn ->
          generate_summary(history, topic, participants, state)
        end)

      {:noreply, %{state | task_ref: task.ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:your_turn, _, _, _, _, _}, state) do
    # Weaver doesn't take turns
    {:noreply, state}
  end

  # Summary task completed
  def handle_info({ref, summary}, %{task_ref: ref} = state) when is_map(summary) do
    Process.demonitor(ref, [:flush])
    Server.attach_summary(state.conversation_id, summary)

    # Notify the spawning agent via PubSub if specified
    if state.spawned_by do
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "conversation:#{state.conversation_id}:summary",
        {:conversation_summary, state.conversation_id, summary}
      )
    end

    {:stop, :normal, state}
  end

  # Summary task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.error(
      "[Weaver] Summary generation crashed for #{state.conversation_id}: #{inspect(reason)}"
    )

    # Attach a minimal fallback summary so the server can complete
    fallback = %{
      topic: "unknown",
      rounds: 0,
      participants: [],
      key_points: ["Summary generation failed"],
      consensus: [],
      disagreements: [],
      open_questions: [],
      recommended_actions: []
    }

    Server.attach_summary(state.conversation_id, fallback)

    if state.spawned_by do
      Phoenix.PubSub.broadcast(
        Loomkin.PubSub,
        "conversation:#{state.conversation_id}:summary",
        {:conversation_summary, state.conversation_id, fallback}
      )
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Summary Generation ---

  defp generate_summary(history, topic, participants, state) do
    messages = build_summary_prompt(history, topic, participants)

    case safe_generate(state.model, messages) do
      {:ok, response} ->
        parse_summary(response, topic, history, participants)

      {:error, reason} ->
        Logger.warning("[Weaver] LLM unavailable: #{inspect(reason)}, using fallback summary")
        fallback_summary(topic, history, participants)
    end
  end

  defp safe_generate(model, messages) do
    Loomkin.LLM.generate_text(model, messages)
  rescue
    error ->
      Logger.warning("[Weaver] LLM raised: #{inspect(error)}")
      {:error, :llm_unavailable}
  end

  defp build_summary_prompt(history, topic, participants) do
    names = participant_names(participants)

    transcript =
      history
      |> Enum.filter(fn entry -> entry.type == :speech end)
      |> Enum.map(fn entry ->
        "[Round #{entry.round}] #{entry.speaker}: #{entry.content}"
      end)
      |> Enum.join("\n")

    rounds = history |> Enum.map(& &1.round) |> Enum.max(fn -> 0 end)

    system_prompt = """
    You are a conversation summarizer. Analyze the following conversation transcript
    and produce a structured summary. Respond with a JSON object containing these fields:

    - key_points: array of the most important points raised (strings)
    - consensus: array of points where participants agreed (strings)
    - disagreements: array of points of contention with who disagreed (strings)
    - open_questions: array of unresolved questions (strings)
    - recommended_actions: array of suggested next steps (strings)

    Be concise. Each item should be one sentence.
    Respond ONLY with the JSON object, no markdown or other text.
    """

    user_prompt = """
    Topic: #{topic}
    Participants: #{Enum.join(names, ", ")}
    Rounds: #{rounds}

    Transcript:
    #{transcript}
    """

    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: user_prompt}
    ]
  end

  defp parse_summary(response, topic, history, participants) do
    text = extract_text(response)
    rounds = history |> Enum.map(& &1.round) |> Enum.max(fn -> 0 end)
    names = participant_names(participants)

    base = %{
      topic: topic,
      rounds: rounds,
      participants: names
    }

    case Jason.decode(text) do
      {:ok, parsed} ->
        Map.merge(base, %{
          key_points: Map.get(parsed, "key_points", []),
          consensus: Map.get(parsed, "consensus", []),
          disagreements: Map.get(parsed, "disagreements", []),
          open_questions: Map.get(parsed, "open_questions", []),
          recommended_actions: Map.get(parsed, "recommended_actions", [])
        })

      {:error, _} ->
        Map.merge(base, %{
          key_points: [text],
          consensus: [],
          disagreements: [],
          open_questions: [],
          recommended_actions: []
        })
    end
  end

  defp extract_text(response) when is_map(response) do
    content = Map.get(response, "content", Map.get(response, :content, []))

    case content do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        blocks
        |> Enum.filter(fn
          %{"type" => "text"} -> true
          %{type: "text"} -> true
          _ -> false
        end)
        |> Enum.map(fn block ->
          Map.get(block, "text", Map.get(block, :text, ""))
        end)
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp extract_text(_), do: ""

  defp fallback_summary(topic, history, participants) do
    names = participant_names(participants)
    speech_entries = Enum.filter(history, fn entry -> entry.type == :speech end)
    rounds = history |> Enum.map(& &1.round) |> Enum.max(fn -> 0 end)

    key_points =
      speech_entries
      |> Enum.take(5)
      |> Enum.map(fn entry -> "#{entry.speaker}: #{String.slice(entry.content, 0, 100)}" end)

    %{
      topic: topic,
      rounds: rounds,
      participants: names,
      key_points: key_points,
      consensus: [],
      disagreements: [],
      open_questions: [],
      recommended_actions: []
    }
  end

  defp participant_names(participants) do
    Enum.map(participants, fn
      %{name: name} -> name
      name when is_binary(name) -> name
    end)
  end
end
