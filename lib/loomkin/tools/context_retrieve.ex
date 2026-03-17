defmodule Loomkin.Tools.ContextRetrieve do
  @moduledoc "Retrieve context from team keepers."

  use Jido.Action,
    name: "context_retrieve",
    description:
      "Retrieve context from team keepers. Use to recall offloaded conversation history, " <>
        "find decisions made earlier, or answer questions about past work. " <>
        "Defaults to smart mode (LLM-summarized answer) for questions, raw mode for keyword lookups.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      query: [type: :string, required: true, doc: "The question or search term"],
      keeper_id: [type: :string, doc: "Specific keeper ID to query (omit to search all)"],
      mode: [
        type: :string,
        doc:
          "Retrieval mode: smart | raw | synthesize (auto-detected if omitted). " <>
            "Use synthesize to combine context from multiple keepers into a unified answer."
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  alias Loomkin.Teams.ContextRetrieval

  @max_result_chars 8000

  @impl true
  def run(params, context) do
    team_id = param!(params, :team_id)
    query = param!(params, :query)
    keeper_id = param(params, :keeper_id)
    mode = param(params, :mode)
    agent_name = param(context, :agent_name)

    if mode == "synthesize" do
      case ContextRetrieval.synthesize(team_id, query, agent_name: agent_name) do
        {:ok, result} ->
          {:ok, %{result: truncate(result, @max_result_chars)}}

        {:error, :not_found} ->
          {:ok, %{result: "No relevant context found for: #{String.slice(query, 0, 80)}"}}
      end
    else
      opts = []
      opts = if keeper_id, do: Keyword.put(opts, :keeper_id, keeper_id), else: opts
      opts = if agent_name, do: Keyword.put(opts, :agent_name, agent_name), else: opts

      opts =
        case mode do
          "smart" -> Keyword.put(opts, :mode, :smart)
          "raw" -> Keyword.put(opts, :mode, :raw)
          _ -> opts
        end

      case ContextRetrieval.retrieve(team_id, query, opts) do
        {:ok, result} when is_binary(result) ->
          {:ok, %{result: truncate(result, @max_result_chars)}}

        {:ok, messages} when is_list(messages) ->
          formatted = format_messages(messages)
          {:ok, %{result: truncate(formatted, @max_result_chars)}}

        {:error, :not_found} ->
          {:ok, %{result: "No relevant context found for: #{String.slice(query, 0, 80)}"}}
      end
    end
  end

  defp format_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      role = msg[:role] || msg["role"] || "unknown"
      content = msg[:content] || msg["content"] || ""
      "[#{role}]: #{content}"
    end)
    |> Enum.join("\n")
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    String.slice(text, 0, max - 3) <> "..."
  end
end
