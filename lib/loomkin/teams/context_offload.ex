defmodule Loomkin.Teams.ContextOffload do
  @moduledoc "Logic for when and how agents offload context to keepers."

  require Logger

  alias Loomkin.Teams.ContextKeeper
  alias Loomkin.Teams.Manager
  alias Loomkin.Session.ContextWindow

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
          marker = %{
            role: :system,
            content: "[Context offloaded] #{index_entry}",
            priority: :high
          }

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
    topic = Keyword.get_lazy(opts, :topic, fn -> generate_topic(messages) end)
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

        Phoenix.PubSub.broadcast(
          Loomkin.PubSub,
          "team:#{team_id}",
          {:keeper_created,
           %{
             id: keeper_state.id,
             topic: topic,
             source: to_string(agent_name),
             tokens: keeper_state.token_count
           }}
        )

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

  @doc """
  Generate a semantic topic for offloaded messages using an LLM call.

  Sends a small prompt asking for a 3-5 word summary. Falls back to
  the heuristic `infer_topic/1` on any failure.
  """
  def generate_topic(messages) do
    content =
      messages
      |> Enum.map(&message_content/1)
      |> Enum.join("\n")
      |> String.slice(0, 2000)

    if String.trim(content) == "" do
      infer_topic(messages)
    else
      model = Loomkin.Teams.ModelRouter.default_model()

      llm_messages = [
        ReqLLM.Context.system(
          "Summarize the main topic of the following conversation in 3-5 words. Reply with ONLY the topic, nothing else."
        ),
        ReqLLM.Context.user(content)
      ]

      # Single attempt only — topic generation is best-effort, not worth retrying
      case Loomkin.LLMRetry.with_retry([max_retries: 0], fn ->
             Loomkin.LLM.generate_text(model, llm_messages, [])
           end) do
        {:ok, response} ->
          topic = ReqLLM.Response.classify(response).text || ""
          topic = String.trim(topic)

          if topic == "" do
            infer_topic(messages)
          else
            String.slice(topic, 0, 80)
          end

        {:error, _} ->
          infer_topic(messages)
      end
    end
  rescue
    e ->
      Logger.warning("[ContextOffload] Topic generation failed: #{Exception.message(e)}")
      infer_topic(messages)
  end

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

  @doc false
  def infer_topic(messages) do
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
