defmodule Loomkin.AgentLoop.Checkpoint do
  @moduledoc """
  Represents a checkpoint during agent loop execution.

  Checkpoints allow external observers (e.g. the Agent GenServer) to inspect
  what the agent is about to do (`:post_llm`) or just did (`:post_tool`), and
  optionally pause execution.

  The checkpoint callback receives a `%Checkpoint{}` and returns either
  `:continue` or `{:pause, reason}`.

  ## Checkpoint types and their fields

  ### `:post_llm`

  Emitted after the LLM responds but before any tool calls are executed.

    * `planned_tools` — list of tool call maps the LLM wants to execute
    * `tool_name` — always `nil`
    * `tool_result` — always `nil`

  ### `:post_tool`

  Emitted after a single tool call has been executed.

    * `tool_name` — the name of the tool that just ran
    * `tool_result` — the string result returned by the tool
    * `planned_tools` — always `nil`

  Both types always carry `agent_name`, `team_id`, `iteration`, and `messages`.
  """

  @type checkpoint_type :: :post_llm | :post_tool

  @type t :: %__MODULE__{
          type: checkpoint_type(),
          agent_name: String.t() | atom() | nil,
          team_id: String.t() | nil,
          iteration: non_neg_integer(),
          planned_tools: [map()] | nil,
          tool_name: String.t() | nil,
          tool_result: String.t() | nil,
          messages: [map()]
        }

  defstruct [
    :type,
    :agent_name,
    :team_id,
    :iteration,
    :planned_tools,
    :tool_name,
    :tool_result,
    messages: []
  ]
end
