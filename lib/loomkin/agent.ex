defmodule Loomkin.Agent do
  @moduledoc """
  Loomkin's AI coding agent, powered by Jido.AI.Agent with ReAct reasoning.

  This module defines the agent with all Loomkin tools registered.
  The Session GenServer manages persistence, context windowing,
  and permissions, then delegates to this agent for the ReAct loop.
  """

  use Jido.AI.Agent,
    name: "loom",
    description: "AI coding assistant that helps write, debug, and maintain software",
    tools: [
      Loomkin.Tools.FileRead,
      Loomkin.Tools.FileWrite,
      Loomkin.Tools.FileEdit,
      Loomkin.Tools.FileSearch,
      Loomkin.Tools.ContentSearch,
      Loomkin.Tools.DirectoryList,
      Loomkin.Tools.Shell,
      Loomkin.Tools.Git,
      Loomkin.Tools.DecisionLog,
      Loomkin.Tools.DecisionQuery,
      Loomkin.Tools.SubAgent
    ],
    system_prompt: "You are Loomkin, an AI coding assistant.",
    max_iterations: 25,
    tool_timeout_ms: 60_000
end
