defmodule LoomkinWeb.TerminalComponent do
  use LoomkinWeb, :live_component

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def render(assigns) do
    ~H"""
    <div class="bg-gray-950 rounded-xl border border-gray-800/80 overflow-hidden font-mono text-xs shadow-sm">
      <%!-- Terminal Chrome --%>
      <div class="px-3 py-2 bg-gradient-to-r from-gray-800 to-gray-800/80 border-b border-gray-800/80 flex items-center gap-2">
        <div class="flex gap-1.5">
          <div class="w-2.5 h-2.5 rounded-full bg-red-500/70 hover:bg-red-500 transition-colors duration-200">
          </div>
          <div class="w-2.5 h-2.5 rounded-full bg-yellow-500/70 hover:bg-yellow-500 transition-colors duration-200">
          </div>
          <div class="w-2.5 h-2.5 rounded-full bg-green-500/70 hover:bg-green-500 transition-colors duration-200">
          </div>
        </div>
        <span class="text-gray-500 text-[10px] ml-1">Terminal</span>
      </div>

      <%!-- Terminal Body --%>
      <div class="p-3 space-y-4 max-h-96 overflow-auto">
        <%!-- Empty State --%>
        <div :if={@commands == []} class="flex items-center justify-center py-8">
          <div class="text-center space-y-2">
            <div class="text-gray-600 text-lg">&#9002;</div>
            <p class="text-gray-600 text-[11px]">No commands executed yet</p>
          </div>
        </div>

        <%!-- Command Blocks --%>
        <div :for={cmd <- @commands} class="space-y-1 group" id={"cmd-#{:erlang.phash2(cmd)}"}>
          <div class="flex items-start gap-1.5">
            <span class="text-emerald-400 select-none leading-relaxed">$</span>
            <span class="text-gray-200 leading-relaxed flex-1">{cmd.command}</span>
            <button
              class="opacity-0 group-hover:opacity-100 transition-opacity duration-200 text-gray-500 hover:text-gray-300 px-1.5 py-0.5 rounded bg-gray-800/50 text-[10px]"
              phx-hook="CopyToClipboard"
              id={"copy-#{:erlang.phash2(cmd)}"}
              data-copy-text={cmd_copy_text(cmd)}
            >
              Copy
            </button>
          </div>
          <pre
            :if={cmd.output && cmd.output != ""}
            class={["pl-4 whitespace-pre-wrap break-all leading-relaxed", output_color(cmd.exit_code)]}
          >{cmd.output}</pre>
          <div
            :if={cmd.exit_code == 0}
            class="pl-4 flex items-center gap-1 text-[10px] text-emerald-500/70"
          >
            <span>&#10003;</span>
            <span>exit 0</span>
          </div>
          <div
            :if={cmd.exit_code != 0}
            class="pl-4 flex items-center gap-1 text-[10px] text-rose-400/80"
          >
            <span>&#10007;</span>
            <span>exit {cmd.exit_code}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp output_color(0), do: "text-gray-400"
  defp output_color(_), do: "text-rose-400/80"

  defp cmd_copy_text(cmd) do
    output = if cmd.output && cmd.output != "", do: "\n#{cmd.output}", else: ""
    "$ #{cmd.command}#{output}"
  end
end
