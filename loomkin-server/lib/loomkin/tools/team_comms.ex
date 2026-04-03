defmodule Loomkin.Tools.TeamComms do
  @moduledoc "Read recent team communications from the signal journal."

  use Jido.Action,
    name: "team_comms",
    description:
      "Read recent team communications (messages, discoveries, task events). " <>
        "Use this to see what your agents have been saying to each other.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID to read comms for"],
      limit: [type: :integer, required: false, doc: "Max events to return (default: 30)"],
      minutes: [
        type: :integer,
        required: false,
        doc: "How far back to look in minutes (default: 30)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2]

  @comms_signal_types [
    "collaboration.peer.message",
    "collaboration.peer.discovery",
    "collaboration.conversation.turn",
    "team.task.created",
    "team.task.completed",
    "team.task.assigned",
    "context.update"
  ]

  @replay_paths ["collaboration.**", "team.**", "context.**"]

  @impl true
  def run(params, _context) do
    team_id = param!(params, :team_id)
    limit = Map.get(params, :limit, 30)
    minutes = Map.get(params, :minutes, 30)

    cutoff = DateTime.add(DateTime.utc_now(), -minutes, :minute)

    recorded_signals =
      Enum.flat_map(@replay_paths, fn path ->
        case Loomkin.Signals.replay(path) do
          {:ok, signals} -> signals
          _ -> []
        end
      end)

    events =
      recorded_signals
      |> Enum.filter(fn rec ->
        Loomkin.Signals.signal_for_team?(rec.signal, team_id) and
          rec.signal.type in @comms_signal_types and
          after_cutoff?(rec, cutoff)
      end)
      |> Enum.sort_by(fn rec -> rec.signal.time || to_string(rec.id) end)
      |> Enum.take(-limit)
      |> Enum.map(&format_event/1)
      |> Enum.reject(&is_nil/1)

    summary =
      if events == [] do
        "No recent team communications in the last #{minutes} minutes."
      else
        header = "Team Communications (last #{minutes} min, #{length(events)} events):\n"
        header <> Enum.join(events, "\n")
      end

    {:ok, %{result: summary}}
  end

  # -- Private helpers --

  defp after_cutoff?(rec, cutoff) do
    case parse_time(rec.signal.time) do
      {:ok, dt} -> DateTime.compare(dt, cutoff) != :lt
      _ -> true
    end
  end

  defp parse_time(nil), do: :unknown

  defp parse_time(time_str) when is_binary(time_str) do
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :unknown
    end
  end

  defp parse_time(_), do: :unknown

  defp format_event(%{signal: %Jido.Signal{} = sig}) do
    time = format_time(sig.time)

    case sig.type do
      "collaboration.peer.message" ->
        from = sig.data[:from] || "unknown"
        to = sig.data[:to] || "team"

        content =
          case sig.data[:message] do
            {:peer_message, _sender, text} -> text
            text when is_binary(text) -> text
            other -> inspect(other)
          end

        "[#{time}] #{from} → #{to}: #{truncate(content, 200)}"

      "collaboration.peer.discovery" ->
        from = sig.data[:from] || "unknown"
        content = sig.data[:content] || sig.data[:message] || "shared a discovery"
        content = if is_binary(content), do: content, else: inspect(content)
        "[#{time}] #{from} 📢 #{truncate(content, 200)}"

      "collaboration.conversation.turn" ->
        speaker = sig.data[:speaker] || "unknown"
        content = sig.data[:content] || ""
        "[#{time}] #{speaker} (conversation): #{truncate(content, 150)}"

      "team.task.created" ->
        title = sig.data[:title] || "untitled"
        "[#{time}] 📋 Task created: #{truncate(title, 200)}"

      "team.task.completed" ->
        agent = sig.data[:agent] || sig.data[:completed_by] || "unknown"
        result = sig.data[:result] || "task completed"
        result = if is_binary(result), do: result, else: inspect(result)
        "[#{time}] ✅ #{agent} completed: #{truncate(result, 200)}"

      "team.task.assigned" ->
        agent = sig.data[:agent] || sig.data[:assigned_to] || "unknown"
        "[#{time}] 📌 #{agent} picked up a task"

      "context.update" ->
        agent = sig.data[:agent] || sig.data[:from] || "unknown"
        payload = sig.data[:payload] || sig.data

        content =
          case payload do
            %{type: :discovery, content: c} when is_binary(c) -> c
            %{content: c} when is_binary(c) -> c
            _ -> "shared a discovery"
          end

        "[#{time}] #{agent} 📢 #{truncate(content, 200)}"

      _ ->
        nil
    end
  end

  defp format_event(_), do: nil

  defp format_time(nil), do: "??:??"

  defp format_time(time_str) when is_binary(time_str) do
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _offset} ->
        Calendar.strftime(dt, "%H:%M")

      _ ->
        "??:??"
    end
  end

  defp format_time(_), do: "??:??"

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max) <> "…"
  end

  defp truncate(text, _max), do: text
end
