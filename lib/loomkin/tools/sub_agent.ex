defmodule Loomkin.Tools.SubAgent do
  @moduledoc "Spawns a read-only search sub-agent to find information in the codebase."

  use Jido.Action,
    name: "sub_agent",
    description:
      "Spawn a read-only search sub-agent to find information in the codebase. " <>
        "Use for complex searches that need multiple steps.",
    schema: [
      task: [type: :string, required: true, doc: "Description of what to search for"],
      scope: [type: :string, doc: "Directory to scope the search to (default: project root)"]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  require Logger

  @max_iterations 10

  @read_only_tools [
    Loomkin.Tools.FileRead,
    Loomkin.Tools.FileSearch,
    Loomkin.Tools.ContentSearch,
    Loomkin.Tools.DirectoryList
  ]

  @impl true
  def run(params, context) do
    task = param!(params, :task)
    project_path = param!(context, :project_path)
    scope = param(params, :scope, project_path)

    # Resolve scope relative to project and validate it's within project bounds
    scope =
      if Path.type(scope) == :absolute do
        scope
      else
        Path.join(project_path, scope)
      end
      |> Path.expand()

    unless String.starts_with?(scope, project_path <> "/") or scope == project_path do
      raise "Scope '#{scope}' is outside the project directory"
    end

    model = weak_model()
    tool_defs = build_tool_definitions()

    system_content =
      "You are a search assistant working in #{scope}. " <>
        "Find information about the following task. Be concise in your findings. " <>
        "Use the available tools to search files and code. " <>
        "When you have found enough information, respond with your findings as plain text."

    messages = [
      ReqLLM.Context.system(system_content),
      ReqLLM.Context.user(task)
    ]

    # Enforce scope: sub-agent tools operate within the resolved scope directory
    sub_context = %{project_path: scope}

    case run_sub_loop(messages, tool_defs, model, sub_context, 0) do
      {:ok, answer} -> {:ok, %{result: answer}}
      {:error, reason} -> {:error, "Sub-agent failed: #{reason}"}
    end
  rescue
    e -> {:error, "Sub-agent error: #{Exception.message(e)}"}
  end

  defp run_sub_loop(_messages, _tool_defs, _model, _context, iteration)
       when iteration >= @max_iterations do
    {:error, "Sub-agent exceeded maximum iterations (#{@max_iterations})"}
  end

  defp run_sub_loop(messages, tool_defs, model, context, iteration) do
    case call_llm(model, messages, tool_defs) do
      {:ok, response} ->
        classified = ReqLLM.Response.classify(response)
        handle_classified(classified, messages, tool_defs, model, context, iteration)

      {:error, reason} ->
        {:error, "LLM call failed: #{inspect(reason)}"}
    end
  end

  defp handle_classified(%{type: :tool_calls} = classified, messages, tool_defs, model, context, iteration) do
    # Add the assistant message with tool calls
    tool_calls_for_context =
      Enum.map(classified.tool_calls, fn tc ->
        {tc[:name] || tc["name"], tc[:arguments] || tc["arguments"] || %{},
         id: tc[:id] || tc["id"]}
      end)

    assistant_msg =
      ReqLLM.Context.assistant(classified.text || "", tool_calls: tool_calls_for_context)

    messages = messages ++ [assistant_msg]

    # Execute each tool call and add results
    messages =
      Enum.reduce(classified.tool_calls, messages, fn tool_call, acc ->
        tool_name = tool_call[:name] || tool_call["name"]
        tool_args = tool_call[:arguments] || tool_call["arguments"] || %{}
        tool_call_id = tool_call[:id] || tool_call["id"] || "call_#{:erlang.unique_integer([:positive])}"

        result = execute_read_tool(tool_name, tool_args, context)

        result_text =
          case result do
            {:ok, %{result: text}} -> text
            {:ok, text} when is_binary(text) -> text
            {:error, text} -> "Error: #{text}"
          end

        acc ++ [ReqLLM.Context.tool_result(tool_call_id, result_text)]
      end)

    run_sub_loop(messages, tool_defs, model, context, iteration + 1)
  end

  defp handle_classified(%{type: :final_answer} = classified, _messages, _tool_defs, _model, _context, _iteration) do
    {:ok, classified.text || "No findings."}
  end

  defp handle_classified(_classified, _messages, _tool_defs, _model, _context, _iteration) do
    {:error, "Unexpected response from sub-agent model"}
  end

  defp execute_read_tool(name, args, context) do
    case Jido.AI.ToolAdapter.lookup_action(name, @read_only_tools) do
      {:ok, tool_module} ->
        Jido.Exec.run(tool_module, args, context, timeout: 30_000)

      {:error, :not_found} ->
        {:error, "Tool '#{name}' not available in sub-agent (read-only tools only)"}
    end
  end

  defp call_llm(model, messages, tool_defs) do
    opts = if tool_defs != [], do: [tools: tool_defs], else: []

    try do
      ReqLLM.generate_text(model, messages, opts)
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp build_tool_definitions do
    Jido.AI.ToolAdapter.from_actions(@read_only_tools)
  end

  defp weak_model do
    if Code.ensure_loaded?(Loomkin.Config) do
      try do
        Loomkin.Config.get(:model, :editor) || "anthropic:claude-haiku-4-5"
      rescue
        _ -> "anthropic:claude-haiku-4-5"
      end
    else
      "anthropic:claude-haiku-4-5"
    end
  end
end
