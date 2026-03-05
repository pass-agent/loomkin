defmodule LoomkinWeb.ChatComponent do
  use LoomkinWeb, :live_component

  def mount(socket) do
    {:ok,
     socket
     |> assign(msg_count: 0, has_messages: false)
     |> stream(:messages, [])}
  end

  def update(assigns, socket) do
    old_count = socket.assigns.msg_count
    messages = assigns[:messages] || []
    new_count = length(messages)

    socket = assign(socket, Map.drop(assigns, [:messages]))

    socket =
      cond do
        # First render with history — reset stream with all messages
        old_count == 0 && new_count > 0 ->
          wrapped = wrap_messages(messages, 0)
          stream(socket, :messages, wrapped, reset: true)

        # New messages appended
        new_count > old_count ->
          new_msgs = Enum.drop(messages, old_count)
          wrapped = wrap_messages(new_msgs, old_count)

          Enum.reduce(wrapped, socket, fn msg, sock ->
            stream_insert(sock, :messages, msg)
          end)

        # No change
        true ->
          socket
      end

    {:ok, assign(socket, msg_count: new_count, has_messages: new_count > 0)}
  end

  defp wrap_messages(messages, start_idx) do
    messages
    |> Enum.with_index(start_idx)
    |> Enum.map(fn {msg, idx} ->
      Map.put(msg, :id, "msg-#{idx}")
    end)
  end

  def handle_event("select_prompt", %{"prompt" => prompt}, socket) do
    send(self(), {:select_prompt, prompt})
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex-1 overflow-auto" id="chat-messages" phx-hook="ScrollToBottom">
      <div class="flex flex-col gap-4 p-4">
        <%!-- Empty State --%>
        <div :if={!@has_messages} class="flex items-center justify-center h-64">
          <div class="text-center space-y-4">
            <div class="w-12 h-12 mx-auto rounded-2xl bg-violet-600/20 flex items-center justify-center shadow-lg shadow-violet-500/10">
              <span class="text-xl font-bold text-violet-400">L</span>
            </div>
            <div>
              <p class="text-lg font-medium text-gray-300">What shall we build today?</p>
              <p class="text-sm text-gray-500 mt-1">Send a message to start your coding session.</p>
            </div>
            <div class="flex flex-wrap gap-2 justify-center pt-2">
              <button
                phx-click="select_prompt"
                phx-value-prompt="Explore this codebase"
                phx-target={@myself}
                class="px-3 py-1.5 text-xs bg-gray-800/80 text-gray-400 rounded-full border border-gray-700/50 hover:border-violet-500/30 hover:text-gray-300 transition-all duration-200 cursor-pointer"
              >
                Explore this codebase
              </button>
              <button
                phx-click="select_prompt"
                phx-value-prompt="Fix a bug"
                phx-target={@myself}
                class="px-3 py-1.5 text-xs bg-gray-800/80 text-gray-400 rounded-full border border-gray-700/50 hover:border-violet-500/30 hover:text-gray-300 transition-all duration-200 cursor-pointer"
              >
                Fix a bug
              </button>
              <button
                phx-click="select_prompt"
                phx-value-prompt="Add a feature"
                phx-target={@myself}
                class="px-3 py-1.5 text-xs bg-gray-800/80 text-gray-400 rounded-full border border-gray-700/50 hover:border-violet-500/30 hover:text-gray-300 transition-all duration-200 cursor-pointer"
              >
                Add a feature
              </button>
            </div>
          </div>
        </div>

        <%!-- Messages (streamed) --%>
        <div id={"#{@id}-message-stream"} phx-update="stream">
          <div :for={{dom_id, msg} <- @streams.messages} id={dom_id} class="animate-fade-in-up">
            <%= case msg.role do %>
              <% :user -> %>
                <div class="flex items-start gap-3 justify-end max-w-[80%] ml-auto">
                  <div class="bg-gray-700/80 rounded-2xl px-4 py-2.5 text-sm shadow-sm">
                    <p class="whitespace-pre-wrap leading-relaxed">{msg.content}</p>
                  </div>
                  <div class="w-7 h-7 rounded-full bg-gradient-to-br from-amber-500 to-orange-600 flex items-center justify-center flex-shrink-0 shadow-sm">
                    <span class="text-xs font-bold text-white">U</span>
                  </div>
                </div>
              <% :assistant -> %>
                <div class="flex items-start gap-3 max-w-[85%]">
                  <div class="w-7 h-7 rounded-full bg-violet-600 flex items-center justify-center flex-shrink-0 shadow-lg shadow-violet-500/30">
                    <span class="text-xs font-bold text-white">L</span>
                  </div>
                  <div class="border-l-2 border-violet-500/40 pl-3 py-0.5">
                    <div class="max-w-none chat-markdown">
                      {render_markdown(msg.content)}
                    </div>
                  </div>
                </div>
              <% :tool -> %>
                <div class="max-w-[85%] ml-10 animate-fade-in-up">
                  <%= if String.starts_with?(msg.content || "", "Error:") do %>
                    <div class="rounded-xl overflow-hidden border border-red-500/30 bg-red-950/20 px-3 py-2">
                      <div class="flex items-center gap-2 text-xs font-medium text-red-400">
                        <span class="text-red-400">&#9888;</span>
                        <span>{tool_display_name(msg)}</span>
                      </div>
                      <pre class="text-xs text-red-300/80 whitespace-pre-wrap mt-1">{msg.content}</pre>
                    </div>
                  <% else %>
                    <div class={"tool-card rounded-xl overflow-hidden border transition-all duration-200 #{tool_card_border(msg)}"}>
                      <div
                        class={"flex items-center gap-2 px-3 py-2 cursor-pointer select-none text-xs font-medium #{tool_card_header(msg)}"}
                        onclick="this.parentElement.classList.toggle('tool-expanded')"
                      >
                        <span class="tool-card-icon">{tool_icon(msg)}</span>
                        <span>{tool_display_name(msg)}</span>
                        <span class="ml-auto text-gray-500 tool-card-chevron transition-transform duration-200">
                          &#9656;
                        </span>
                      </div>
                      <div class="tool-card-body px-3 py-2 border-t border-gray-800/50 bg-gray-900/30">
                        <pre class="text-xs text-gray-400 whitespace-pre-wrap overflow-x-auto font-mono leading-relaxed tool-file-paths">{truncate_result(msg.content)}</pre>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% _ -> %>
                <div class="text-xs text-gray-500 px-3">
                  {inspect(msg)}
                </div>
            <% end %>
          </div>
        </div>

        <%!-- Streaming / Thinking State --%>
        <div
          :if={@streaming || @status == :thinking}
          class="flex items-start gap-3 max-w-[85%] animate-fade-in-up"
        >
          <div class="w-7 h-7 rounded-full bg-violet-600 flex items-center justify-center flex-shrink-0 shadow-lg shadow-violet-500/30">
            <span class="text-xs font-bold text-white">L</span>
          </div>
          <%= if @streaming && @streaming_content != "" do %>
            <div class="border-l-2 border-violet-500/40 pl-3 py-0.5">
              <div class="max-w-none chat-markdown">
                {render_markdown(@streaming_content, streaming: true)}
              </div>
              <span class="inline-block w-2 h-4 bg-violet-400 animate-pulse ml-0.5"></span>
            </div>
          <% else %>
            <div class="bg-gray-800/60 rounded-xl px-4 py-3 shadow-sm shadow-violet-500/5 border border-violet-500/10">
              <div class="flex items-center gap-1.5">
                <span class="thinking-dot w-2 h-2 bg-violet-400 rounded-full"></span>
                <span class="thinking-dot w-2 h-2 bg-violet-400 rounded-full"></span>
                <span class="thinking-dot w-2 h-2 bg-violet-400 rounded-full"></span>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Architect Plan Progress --%>
        <div :if={@plan_steps != []} class="ml-10 animate-fade-in-up">
          <div class="border border-violet-500/20 rounded-xl overflow-hidden bg-gray-900/50">
            <div class="flex items-center gap-2 px-3 py-2 bg-violet-500/10 border-b border-violet-500/20">
              <span class="text-violet-400 text-sm">&#9881;</span>
              <span class="text-xs font-medium text-violet-300">
                {if @architect_phase == :executing, do: "Executing Plan", else: "Planning..."}
              </span>
            </div>
            <div class="p-3 space-y-1.5">
              <div
                :for={{step, idx} <- Enum.with_index(@plan_steps)}
                class="flex items-center gap-2 text-xs"
              >
                <%= cond do %>
                  <% @current_step != nil && idx < @current_step -> %>
                    <span class="text-green-400">&#10003;</span>
                  <% @current_step == idx -> %>
                    <span class="text-violet-400 animate-spin">&#9881;</span>
                  <% true -> %>
                    <span class="text-gray-600">&#9675;</span>
                <% end %>
                <span class={"font-mono #{if @current_step == idx, do: "text-violet-300", else: "text-gray-400"}"}>
                  {step["action"]} {step["file"]}
                </span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Tool Executing State --%>
        <div :if={@current_tool} class="flex items-center gap-2 ml-10 animate-fade-in-up">
          <div class="flex items-center gap-2 px-3 py-1.5 bg-gray-800/40 rounded-lg border border-violet-500/10 shadow-sm shadow-violet-500/5">
            <svg
              class="animate-spin h-3.5 w-3.5 text-violet-400"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
            >
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
              </circle>
              <path
                class="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
              >
              </path>
            </svg>
            <span class="text-xs text-gray-400">
              Running <span class="text-violet-400 font-medium">{@current_tool}</span>
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_markdown(content, opts \\ [])
  defp render_markdown(nil, _opts), do: ""
  defp render_markdown("", _opts), do: ""

  defp render_markdown(content, opts) when is_binary(content) do
    streaming = Keyword.get(opts, :streaming, false)

    doc =
      MDEx.new(streaming: streaming, render: [unsafe_: true])
      |> MDEx.Document.put_markdown(content)

    case MDEx.to_html(doc) do
      {:ok, html} ->
        Phoenix.HTML.raw(html)

      _ ->
        Phoenix.HTML.raw(
          "<p>#{Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(content))}</p>"
        )
    end
  end

  defp render_markdown(_, _opts), do: ""

  defp truncate_result(nil), do: ""

  defp truncate_result(text) when byte_size(text) > 2000 do
    String.slice(text, 0, 2000) <> "\n... (truncated)"
  end

  defp truncate_result(text), do: text

  # Tool card styling helpers

  defp tool_call_id(msg), do: msg[:tool_call_id] || ""

  defp tool_type(msg) do
    id = tool_call_id(msg)

    cond do
      String.contains?(id, "file") or String.contains?(id, "read") or
        String.contains?(id, "write") or String.contains?(id, "edit") ->
        :file

      String.contains?(id, "shell") or String.contains?(id, "bash") or
          String.contains?(id, "exec") ->
        :shell

      String.contains?(id, "search") or String.contains?(id, "grep") or
          String.contains?(id, "glob") ->
        :search

      String.contains?(id, "decision") or String.contains?(id, "plan") ->
        :decision

      true ->
        :default
    end
  end

  defp tool_card_header(msg) do
    case tool_type(msg) do
      :file -> "bg-violet-500/10 text-violet-300"
      :shell -> "bg-emerald-500/10 text-emerald-300"
      :search -> "bg-amber-500/10 text-amber-300"
      :decision -> "bg-purple-500/10 text-purple-300"
      :default -> "bg-gray-800/50 text-gray-400"
    end
  end

  defp tool_card_border(msg) do
    case tool_type(msg) do
      :file -> "border-violet-500/20"
      :shell -> "border-emerald-500/20"
      :search -> "border-amber-500/20"
      :decision -> "border-purple-500/20"
      :default -> "border-gray-700/50"
    end
  end

  defp tool_icon(msg) do
    case tool_type(msg) do
      :file -> "&#128196;"
      :shell -> "&#9002;"
      :search -> "&#128269;"
      :decision -> "&#9670;"
      :default -> "&#9881;"
    end
  end

  defp tool_display_name(msg) do
    id = tool_call_id(msg)
    if id == "", do: "Tool result", else: id
  end
end
