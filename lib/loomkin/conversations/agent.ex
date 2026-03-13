defmodule Loomkin.Conversations.Agent do
  @moduledoc """
  Lightweight agent optimized for conversation. Uses a persona-driven system prompt,
  reads from shared history via ConversationServer, and has minimal tools
  (speak, react, yield, end_conversation).

  Short-lived: spawned for a single conversation and terminates when it ends.
  """

  use GenServer

  require Logger

  alias Loomkin.Conversations.Persona
  alias Loomkin.Conversations.Tools.EndConversation
  alias Loomkin.Conversations.Tools.React
  alias Loomkin.Conversations.Tools.Speak
  alias Loomkin.Conversations.Tools.Yield

  @conversation_tools [Speak, React, Yield, EndConversation]

  defstruct [
    :conversation_id,
    :team_id,
    :name,
    :persona,
    :model,
    :topic,
    :task_ref,
    tokens_used: 0
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns the list of conversation tool modules."
  def conversation_tools, do: @conversation_tools

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    team_id = Keyword.fetch!(opts, :team_id)
    persona = Keyword.fetch!(opts, :persona)
    model = Keyword.fetch!(opts, :model)
    topic = Keyword.fetch!(opts, :topic)

    # Subscribe to conversation PubSub for turn notifications
    Phoenix.PubSub.subscribe(Loomkin.PubSub, "conversation:#{conversation_id}")

    state = %__MODULE__{
      conversation_id: conversation_id,
      team_id: team_id,
      name: persona.name,
      persona: persona,
      model: model,
      topic: topic
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:your_turn, conversation_id, history, topic, context, agent_name}, state) do
    if agent_name == state.name and conversation_id == state.conversation_id and
         is_nil(state.task_ref) do
      # Dispatch LLM call to a Task to avoid blocking the mailbox
      task =
        Task.Supervisor.async_nolink(Loomkin.Healing.TaskSupervisor, fn ->
          run_turn(history, topic, context, state)
        end)

      {:noreply, %{state | task_ref: task.ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:summarize, _, _, _, _}, state) do
    # Conversation ended, cancel in-flight task and stop
    cancel_task(state)
    {:stop, :normal, state}
  end

  # Task completed successfully
  def handle_info({ref, {:ok, tokens}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task_ref: nil, tokens_used: state.tokens_used + tokens}}
  end

  # Task failed
  def handle_info({ref, {:error, _reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task_ref: nil}}
  end

  # Task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.warning("[ConversationAgent] LLM task crashed for #{state.name}: #{inspect(reason)}")

    # Yield so the conversation can continue
    Loomkin.Conversations.Server.yield(
      state.conversation_id,
      state.name,
      "error generating response"
    )

    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_task(state)
    :ok
  end

  # --- Private ---

  defp run_turn(history, topic, context, state) do
    messages = build_messages(history, topic, context, state)
    tool_defs = Jido.AI.ToolAdapter.from_actions(@conversation_tools)

    exec_context = %{
      conversation_id: state.conversation_id,
      agent_name: state.name,
      team_id: state.team_id
    }

    case Loomkin.LLM.generate_text(state.model, messages, tools: tool_defs) do
      {:ok, response} ->
        tokens = extract_token_count(response)
        execute_tool_calls(response, exec_context)
        {:ok, tokens}

      {:error, reason} ->
        Logger.warning("[ConversationAgent] LLM error for #{state.name}: #{inspect(reason)}")

        Loomkin.Conversations.Server.yield(
          state.conversation_id,
          state.name,
          "error generating response"
        )

        {:error, reason}
    end
  end

  defp build_messages(history, topic, context, state) do
    system = Persona.system_prompt(state.persona, topic, context)

    conversation_msgs =
      history
      |> Enum.filter(fn entry -> entry.type == :speech or entry.type == :yield end)
      |> Enum.map(fn entry ->
        if entry.speaker == state.name do
          %{role: "assistant", content: entry.content}
        else
          %{role: "user", content: "[#{entry.speaker}]: #{entry.content}"}
        end
      end)

    [%{role: "system", content: system} | conversation_msgs]
  end

  defp execute_tool_calls(response, exec_context) do
    tool_calls = extract_tool_calls(response)

    Enum.each(tool_calls, fn {tool_name, tool_args} ->
      case Jido.AI.ToolAdapter.lookup_action(tool_name, @conversation_tools) do
        {:ok, tool_module} ->
          case Jido.Exec.run(tool_module, tool_args, exec_context, timeout: 10_000) do
            {:ok, _} ->
              :ok

            {:error, err} ->
              Logger.warning("[ConversationAgent] Tool #{tool_name} failed: #{inspect(err)}")
          end

        {:error, :not_found} ->
          Logger.warning("[ConversationAgent] Unknown tool: #{tool_name}")
      end
    end)
  end

  defp extract_tool_calls(response) when is_map(response) do
    # Handle ReqLLM response format with tool_calls in content blocks
    content = Map.get(response, "content", Map.get(response, :content, []))

    content
    |> List.wrap()
    |> Enum.filter(fn
      %{"type" => "tool_use"} -> true
      %{type: "tool_use"} -> true
      _ -> false
    end)
    |> Enum.map(fn block ->
      name = Map.get(block, "name", Map.get(block, :name))
      input = Map.get(block, "input", Map.get(block, :input, %{}))
      {name, input}
    end)
  end

  defp extract_tool_calls(_), do: []

  defp extract_token_count(response) when is_map(response) do
    usage = Map.get(response, "usage", Map.get(response, :usage, %{}))

    input = Map.get(usage, "input_tokens", Map.get(usage, :input_tokens, 0))
    output = Map.get(usage, "output_tokens", Map.get(usage, :output_tokens, 0))
    input + output
  end

  defp extract_token_count(_), do: 0

  defp cancel_task(%{task_ref: nil}), do: :ok

  defp cancel_task(%{task_ref: ref}) do
    Process.demonitor(ref, [:flush])
    :ok
  end
end
