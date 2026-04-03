defmodule Loomkin.Tools.GenerateWriteup do
  @moduledoc "Agent tool to generate a PR writeup from the decision graph."

  use Jido.Action,
    name: "generate_writeup",
    description:
      "Generate a PR writeup from the decision graph. Returns Markdown text summarizing goals, decisions, implementation, and results.",
    schema: [
      title: [type: :string, doc: "PR title"],
      root_id: [type: :string, doc: "Root node ID to generate from (traverses children)"]
    ]

  import Loomkin.Tool, only: [param: 2]

  alias Loomkin.Decisions.Writeup

  @impl true
  def run(params, context) do
    opts = []

    opts =
      case param(params, :title) do
        nil -> opts
        title -> Keyword.put(opts, :title, title)
      end

    opts =
      case param(params, :root_id) do
        nil -> opts
        root_id -> Keyword.put(opts, :root_ids, [root_id])
      end

    opts =
      case param(context, :team_id) do
        nil -> opts
        team_id -> Keyword.put(opts, :team_id, team_id)
      end

    opts =
      case param(context, :session_id) do
        nil -> opts
        session_id -> Keyword.put(opts, :session_id, session_id)
      end

    {:ok, markdown} = Writeup.generate(opts)
    {:ok, %{result: markdown}}
  end
end
