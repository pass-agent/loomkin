defmodule Loomkin.Teams.QueuedMessage do
  @moduledoc """
  Wraps messages in the agent's queue with metadata for UI visibility and manipulation.

  When the agent's loop is active, incoming messages are classified by PriorityRouter
  and stored as `%QueuedMessage{}` structs instead of bare tuples. This enables the UI
  to display, edit, reorder, squash, and delete queued messages before they are dispatched.
  """

  @type source :: :user | :system | :peer | :scheduled
  @type priority :: :urgent | :high | :normal
  @type status :: :pending | :editing | :squashed

  @type t :: %__MODULE__{
          id: String.t(),
          content: term(),
          source: source(),
          priority: priority(),
          status: status(),
          queued_at: DateTime.t(),
          metadata: map()
        }

  defstruct [
    :id,
    :content,
    :source,
    :priority,
    :status,
    :queued_at,
    :metadata
  ]

  @doc """
  Creates a new QueuedMessage wrapping the given content.

  ## Options

    * `:priority` - `:urgent | :high | :normal` (default: `:normal`)
    * `:source` - `:user | :system | :peer | :scheduled` (default: `:system`)
    * `:status` - `:pending | :editing | :squashed` (default: `:pending`)
    * `:metadata` - optional map of additional data (default: `%{}`)
  """
  @spec new(term(), keyword()) :: t()
  def new(content, opts \\ []) do
    %__MODULE__{
      id: generate_id(),
      content: content,
      source: Keyword.get(opts, :source, :system),
      priority: Keyword.get(opts, :priority, :normal),
      status: Keyword.get(opts, :status, :pending),
      queued_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Extracts the original content for dispatch.

  When draining queues, this unwraps the QueuedMessage back to the bare
  message that the agent's `handle_info` clauses expect.
  """
  @spec to_dispatchable(t()) :: term()
  def to_dispatchable(%__MODULE__{content: content}), do: content

  @doc "Convert to a plain map safe for JSON serialization and signal transport."
  @spec to_serializable(t()) :: map()
  def to_serializable(%__MODULE__{} = qm) do
    %{
      id: qm.id,
      content: serialize_content(qm.content),
      source: qm.source,
      priority: qm.priority,
      status: qm.status,
      queued_at: qm.queued_at,
      metadata: qm.metadata
    }
  end

  defp serialize_content({:inject_system_message, text}) when is_binary(text), do: text
  defp serialize_content(text) when is_binary(text), do: text
  defp serialize_content(other), do: inspect(other)

  defp generate_id do
    "qm_#{:erlang.unique_integer([:positive, :monotonic])}"
  end
end
