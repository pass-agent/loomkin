defmodule Loomkin do
  @moduledoc """
  Loomkin — An Elixir-native AI coding assistant.

  Weaves together LLM reasoning, code intelligence, and a persistent decision
  graph to help you write, debug, and maintain software.

  ## Features

  - Interactive CLI and web UI (Phoenix LiveView)
  - Decision graph for persistent reasoning context
  - 16+ LLM providers via req_llm
  - OTP supervision and fault tolerance
  - File editing, shell execution, git operations
  """

  @version Mix.Project.config()[:version]

  def version, do: @version
end
