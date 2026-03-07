defmodule LoomkinWeb.DiffComponent do
  @moduledoc "LiveComponent for displaying file diffs with unified diff view."

  use LoomkinWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, diffs: [], collapsed: MapSet.new(), parsed_cache: %{}, parsed_diffs: [])}
  end

  @impl true
  def update(assigns, socket) do
    new_diffs = assigns[:diffs] || []
    prev_diffs = socket.assigns[:diffs]

    socket = assign(socket, assigns)

    if new_diffs != prev_diffs do
      prev_cache = socket.assigns.parsed_cache
      {parsed_diffs, new_cache} = parse_diffs_incremental(new_diffs, prev_cache)
      {:ok, assign(socket, parsed_diffs: parsed_diffs, parsed_cache: new_cache)}
    else
      {:ok, socket}
    end
  end

  defp parse_diffs_incremental(diffs, prev_cache) do
    {parsed_diffs, new_cache} =
      Enum.map_reduce(diffs, %{}, fn diff, cache_acc ->
        cache_key = diff_cache_key(diff)

        case Map.get(prev_cache, cache_key) do
          nil ->
            parsed = parse_diff(diff)
            {parsed, Map.put(cache_acc, cache_key, parsed)}

          cached ->
            {cached, Map.put(cache_acc, cache_key, cached)}
        end
      end)

    {parsed_diffs, new_cache}
  end

  defp diff_cache_key(%{file_path: file_path, hunks: hunks}) when is_list(hunks),
    do: {:hunks, file_path, :erlang.phash2(hunks)}

  defp diff_cache_key(%{file_path: file_path, old_content: old, new_content: new}),
    do: {:content, file_path, :erlang.phash2({old, new})}

  defp diff_cache_key(%{file_path: file_path} = entry),
    do: {:entry, file_path, :erlang.phash2(entry)}

  defp diff_cache_key(raw) when is_binary(raw),
    do: {:raw, :erlang.phash2(raw)}

  @impl true
  def handle_event("toggle_diff", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, idx) do
        MapSet.delete(collapsed, idx)
      else
        MapSet.put(collapsed, idx)
      end

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full bg-gray-950 text-gray-100 font-mono text-sm">
      <div class="px-3 py-2 border-b border-gray-800">
        <h3 class="text-xs font-semibold text-gray-400 uppercase tracking-wider">Changes</h3>
      </div>

      <div class="flex-1 overflow-y-auto">
        <%!-- Empty State --%>
        <%= if @parsed_diffs == [] do %>
          <div class="flex items-center justify-center h-full">
            <div class="text-center space-y-2">
              <div class="text-gray-600 text-2xl">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-8 w-8 mx-auto text-gray-600"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  stroke-width="1.5"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z"
                  />
                </svg>
              </div>
              <p class="text-gray-500 text-xs">No changes to review</p>
            </div>
          </div>
        <% else %>
          <div
            :for={{diff, idx} <- Enum.with_index(@parsed_diffs)}
            class="border-b border-gray-800/60 animate-fade-in-up"
          >
            <%!-- File Header --%>
            <div
              class="flex items-center gap-2 px-3 py-2.5 bg-gray-900/40 cursor-pointer hover:bg-gray-800/50 sticky top-0 z-10 transition-colors duration-200 border-b border-gray-800/40"
              phx-click="toggle_diff"
              phx-value-index={idx}
              phx-target={@myself}
            >
              <span class="text-gray-500 transition-transform duration-200">
                <%= if MapSet.member?(@collapsed, idx) do %>
                  &#9656;
                <% else %>
                  &#9662;
                <% end %>
              </span>
              <%!-- File Icon --%>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-3.5 w-3.5 text-gray-500 flex-shrink-0"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m2.25 0H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z"
                />
              </svg>
              <span class="text-violet-400 truncate text-xs">{diff.file_path}</span>
              <div class="ml-auto flex items-center gap-1.5">
                <span
                  :if={diff.additions > 0}
                  class="text-[10px] px-1.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 font-medium"
                >
                  +{diff.additions}
                </span>
                <span
                  :if={diff.deletions > 0}
                  class="text-[10px] px-1.5 py-0.5 rounded-full bg-rose-500/10 text-rose-400 font-medium"
                >
                  -{diff.deletions}
                </span>
              </div>
            </div>

            <%!-- Diff Lines --%>
            <div :if={not MapSet.member?(@collapsed, idx)} class="overflow-x-auto">
              <table class="w-full border-collapse">
                <tbody>
                  <tr :for={line <- diff.lines} class={line_row_class(line.type)}>
                    <td class={[
                      "w-10 text-right pr-2 select-none text-[10px] border-r border-gray-800/30",
                      line_number_class(line.type)
                    ]}>
                      {line.old_num || ""}
                    </td>
                    <td class={[
                      "w-10 text-right pr-2 select-none text-[10px] border-r border-gray-800/30",
                      line_number_class(line.type)
                    ]}>
                      {line.new_num || ""}
                    </td>
                    <td class={["px-3 py-0 whitespace-pre text-xs", line_class(line.type)]}>
                      <span class={["select-none mr-2", line_marker_class(line.type)]}>{line_marker(line.type)}</span>{line.text}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Diff Parsing ---

  @doc """
  Parses a diff entry into a structured format for rendering.

  Accepts either:
  - A map with `:file_path` and `:hunks` (unified diff text)
  - A map with `:file_path`, `:old_content`, and `:new_content` (compute diff)
  - A raw tool result string (best-effort parse)
  """
  def parse_diff(%{file_path: file_path, hunks: hunks}) when is_list(hunks) do
    lines = Enum.flat_map(hunks, &parse_hunk/1)
    additions = Enum.count(lines, &(&1.type == :add))
    deletions = Enum.count(lines, &(&1.type == :del))
    %{file_path: file_path, lines: lines, additions: additions, deletions: deletions}
  end

  def parse_diff(%{file_path: file_path, old_content: old_content, new_content: new_content}) do
    lines = compute_simple_diff(old_content || "", new_content || "")
    additions = Enum.count(lines, &(&1.type == :add))
    deletions = Enum.count(lines, &(&1.type == :del))
    %{file_path: file_path, lines: lines, additions: additions, deletions: deletions}
  end

  def parse_diff(%{file_path: file_path} = entry) do
    text = Map.get(entry, :description, Map.get(entry, :text, ""))

    lines =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {line, num} ->
        %{type: :context, text: line, old_num: num, new_num: num}
      end)

    %{file_path: file_path, lines: lines, additions: 0, deletions: 0}
  end

  def parse_diff(raw) when is_binary(raw) do
    parse_edit_result(raw)
  end

  @doc """
  Parses a tool result string (from file_edit) and extracts file path and change description.
  Returns a structured diff entry for rendering.
  """
  def parse_edit_result(text) do
    {file_path, body} = extract_file_path(text)

    lines =
      body
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {line, num} ->
        cond do
          String.starts_with?(line, "+") ->
            %{type: :add, text: String.slice(line, 1..-1//1), old_num: nil, new_num: num}

          String.starts_with?(line, "-") ->
            %{type: :del, text: String.slice(line, 1..-1//1), old_num: num, new_num: nil}

          String.starts_with?(line, "@@") ->
            %{type: :hunk_header, text: line, old_num: nil, new_num: nil}

          true ->
            %{type: :context, text: line, old_num: num, new_num: num}
        end
      end)

    additions = Enum.count(lines, &(&1.type == :add))
    deletions = Enum.count(lines, &(&1.type == :del))

    %{file_path: file_path, lines: lines, additions: additions, deletions: deletions}
  end

  # --- Private helpers ---

  defp extract_file_path(text) do
    case Regex.run(~r/(?:^|\n)[-+]{3}\s+[ab]\/(.+)/, text) do
      [_, path] ->
        {path, text}

      nil ->
        case Regex.run(~r/^File:\s*(.+)/m, text) do
          [_, path] -> {String.trim(path), text}
          nil -> {"unknown", text}
        end
    end
  end

  defp parse_hunk(hunk) when is_binary(hunk) do
    hunk
    |> String.split("\n")
    |> parse_hunk_lines(1, 1, [])
  end

  defp parse_hunk(hunk) when is_map(hunk) do
    text = Map.get(hunk, :text, Map.get(hunk, "text", ""))
    parse_hunk(text)
  end

  defp parse_hunk_lines([], _old, _new, acc), do: Enum.reverse(acc)

  defp parse_hunk_lines([line | rest], old_num, new_num, acc) do
    cond do
      String.starts_with?(line, "@@") ->
        {o, n} = parse_hunk_header(line)
        entry = %{type: :hunk_header, text: line, old_num: nil, new_num: nil}
        parse_hunk_lines(rest, o, n, [entry | acc])

      String.starts_with?(line, "+") ->
        entry = %{type: :add, text: String.slice(line, 1..-1//1), old_num: nil, new_num: new_num}
        parse_hunk_lines(rest, old_num, new_num + 1, [entry | acc])

      String.starts_with?(line, "-") ->
        entry = %{type: :del, text: String.slice(line, 1..-1//1), old_num: old_num, new_num: nil}
        parse_hunk_lines(rest, old_num + 1, new_num, [entry | acc])

      true ->
        text = if String.starts_with?(line, " "), do: String.slice(line, 1..-1//1), else: line
        entry = %{type: :context, text: text, old_num: old_num, new_num: new_num}
        parse_hunk_lines(rest, old_num + 1, new_num + 1, [entry | acc])
    end
  end

  defp parse_hunk_header(header) do
    case Regex.run(~r/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, header) do
      [_, old_start, new_start] ->
        {String.to_integer(old_start), String.to_integer(new_start)}

      _ ->
        {1, 1}
    end
  end

  defp compute_simple_diff(old_text, new_text) do
    old_lines = String.split(old_text, "\n")
    new_lines = String.split(new_text, "\n")

    old_set = MapSet.new(old_lines)
    new_set = MapSet.new(new_lines)

    removed =
      old_lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> MapSet.member?(new_set, line) end)
      |> Enum.map(fn {line, num} -> %{type: :del, text: line, old_num: num, new_num: nil} end)

    added =
      new_lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> MapSet.member?(old_set, line) end)
      |> Enum.map(fn {line, num} -> %{type: :add, text: line, old_num: nil, new_num: num} end)

    context =
      new_lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> MapSet.member?(old_set, line) end)
      |> Enum.map(fn {line, num} -> %{type: :context, text: line, old_num: num, new_num: num} end)

    removed ++ added ++ context
  end

  defp line_row_class(:hunk_header), do: "border-l-2 border-violet-500/30"
  defp line_row_class(_), do: ""

  defp line_class(:add), do: "bg-emerald-500/10"
  defp line_class(:del), do: "bg-rose-500/10"
  defp line_class(:hunk_header), do: "bg-violet-900/10 text-violet-400 text-[11px]"
  defp line_class(:context), do: ""

  defp line_number_class(:add), do: "text-emerald-600 bg-emerald-500/5"
  defp line_number_class(:del), do: "text-rose-600 bg-rose-500/5"
  defp line_number_class(_), do: "text-gray-600"

  defp line_marker(:add), do: "+"
  defp line_marker(:del), do: "-"
  defp line_marker(:hunk_header), do: ""
  defp line_marker(:context), do: " "

  defp line_marker_class(:add), do: "text-emerald-400"
  defp line_marker_class(:del), do: "text-rose-400"
  defp line_marker_class(_), do: "text-gray-600"
end
