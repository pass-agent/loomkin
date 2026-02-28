defmodule Loom.Teams.ContextOffload do
  @moduledoc "Logic for when and how agents offload context to keepers."

  alias Loom.Teams.{ContextKeeper, Manager}
  alias Loom.Session.ContextWindow

  @offload_threshold 0.60
  @chars_per_token 4

  @doc """
  Check if an agent should offload context, and do it if needed.

  Returns `{:offloaded, updated_messages, index_entry}` if offloading occurred,
  or `:noop` if the agent is below threshold.
  """
  def maybe_offload(agent_state) do
    model_limit = ContextWindow.model_limit(agent_state.model)
    current_tokens = estimate_tokens(agent_state.messages)
    threshold = trunc(model_limit * @offload_threshold)

    if current_tokens > threshold do
      {offload_msgs, keep_msgs} = split_at_topic_boundary(agent_state.messages)

      case offload_to_keeper(agent_state.team_id, agent_state.name, offload_msgs) do
        {:ok, _pid, index_entry} ->
          # Prepend index entry as a system note so agent knows context was saved
          marker = %{role: :system, content: "[Context offloaded] #{index_entry}"}
          {:offloaded, [marker | keep_msgs], index_entry}

        {:error, _reason} ->
          :noop
      end
    else
      :noop
    end
  end

  @doc """
  Split messages at a topic boundary.

  Heuristic: look for natural breaks — a user message following a tool result sequence.
  Fallback: split at oldest 30% of messages.

  Returns `{offload_messages, keep_messages}`.
  """
  def split_at_topic_boundary(messages) when length(messages) < 4 do
    {[], messages}
  end

  def split_at_topic_boundary(messages) do
    target_split = trunc(length(messages) * 0.3)
    target_split = max(target_split, 1)

    # Look for a natural break point near the target
    split_index = find_break_point(messages, target_split)

    Enum.split(messages, split_index)
  end

  @doc """
  Spawn a keeper with the offloaded messages.

  Returns `{:ok, keeper_pid, index_entry}` or `{:error, reason}`.
  """
  def offload_to_keeper(team_id, agent_name, messages, opts \\ []) do
    topic = Keyword.get(opts, :topic, infer_topic(messages))
    metadata = Keyword.get(opts, :metadata, %{})

    case Manager.spawn_keeper(team_id,
           topic: topic,
           source_agent: to_string(agent_name),
           messages: messages,
           metadata: metadata
         ) do
      {:ok, pid} ->
        entry = ContextKeeper.index_entry(pid)
        keeper_state = ContextKeeper.get_state(pid)

        Phoenix.PubSub.broadcast(Loom.PubSub, "team:#{team_id}", {:keeper_created, %{
          id: keeper_state.id,
          topic: topic,
          source: to_string(agent_name),
          tokens: keeper_state.token_count
        }})

        {:ok, pid, entry}

      error ->
        {:error, error}
    end
  end

  @doc "Estimate token count for a list of messages."
  def estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(fn msg ->
      content = message_content(msg)
      div(String.length(content), @chars_per_token) + 4
    end)
    |> Enum.sum()
  end

  def estimate_tokens(_), do: 0

  # --- Private ---

  defp find_break_point(messages, target) do
    # Search in a window around the target for a user message following assistant/tool content
    window_start = max(target - 3, 1)
    window_end = min(target + 3, length(messages) - 1)

    break =
      window_start..window_end
      |> Enum.find(fn i ->
        msg = Enum.at(messages, i)
        prev = Enum.at(messages, i - 1)
        is_user_message?(msg) && !is_user_message?(prev)
      end)

    break || target
  end

  defp is_user_message?(%{role: :user}), do: true
  defp is_user_message?(%{role: "user"}), do: true
  defp is_user_message?(%{"role" => "user"}), do: true
  defp is_user_message?(_), do: false

  defp infer_topic(messages) do
    # Use first user message content as topic hint (truncated)
    first_user =
      Enum.find(messages, fn msg -> is_user_message?(msg) end)

    case first_user do
      nil ->
        "offloaded-context"

      msg ->
        message_content(msg)
        |> String.slice(0, 60)
        |> String.trim()
        |> case do
          "" -> "offloaded-context"
          topic -> topic
        end
    end
  end

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(%{"content" => content}) when is_binary(content), do: content
  defp message_content(_), do: ""
end
