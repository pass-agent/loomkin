defmodule LoomkinWeb.SmartAssignmentTransparencyTest do
  @moduledoc "Tests for smart assignment transparency — capability reasoning in comms events."

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]

  alias LoomkinWeb.AgentCommsComponent

  describe "assignment reasoning in comms feed" do
    test "task_assigned event with capability metadata renders reasoning section" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :task_assigned,
        agent: "coder-1",
        content: "Assigned: Best at coding (score: 1.58, 3/3 success)",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{
          task_title: "Fix login bug",
          task_type: :coding,
          chosen_score: 1.58,
          chosen_stats: %{successes: 3, failures: 0},
          reason: "Best at coding (score: 1.58, 3/3 success)",
          alternatives: [
            %{agent: "coder-2", score: 0.62, stats: %{successes: 2, failures: 1}}
          ]
        }
      }

      html = render_comms_feed([event])

      # Assignment reasoning should be rendered
      assert html =~ "Task type:"
      assert html =~ "coding"
      assert html =~ "Capability score:"
      assert html =~ "1.58"
      assert html =~ "Alternatives:"
      assert html =~ "coder-2"
      assert html =~ "0.62"
    end

    test "task_assigned event without capability metadata shows plain content" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :task_assigned,
        agent: "agent-1",
        content: "Picked up a task",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{}
      }

      html = render_comms_feed([event])

      # Should show basic content, no reasoning section
      assert html =~ "Picked up a task"
      refute html =~ "Task type:"
      refute html =~ "Capability score:"
    end

    test "task_assigned event with no alternatives shows score without alternatives section" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :task_assigned,
        agent: "solo-agent",
        content: "Assigned: Best at debugging (score: 2.0, 4/4 success)",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{
          task_title: "Debug crash",
          task_type: :debugging,
          chosen_score: 2.0,
          chosen_stats: %{successes: 4, failures: 0},
          reason: "Best at debugging (score: 2.0, 4/4 success)",
          alternatives: []
        }
      }

      html = render_comms_feed([event])

      assert html =~ "debugging"
      assert html =~ "2.0"
      # No alternatives should be listed
      refute html =~ "Alternatives:"
    end

    test "task_assigned event with nil chosen_score shows task type only" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :task_assigned,
        agent: "fallback-agent",
        content: "Picked up: Write tests",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{
          task_title: "Write tests",
          task_type: :testing,
          chosen_score: nil,
          chosen_stats: nil,
          reason: nil,
          alternatives: []
        }
      }

      html = render_comms_feed([event])

      assert html =~ "testing"
      refute html =~ "Capability score:"
    end
  end

  # Helper to render the comms feed component with given events as a stream
  defp render_comms_feed(events) do
    stream_items =
      Enum.map(events, fn event ->
        {"comms-events-#{event.id}", event}
      end)

    assigns = %{stream: stream_items, event_count: length(events), id: "test-comms"}

    Phoenix.LiveViewTest.rendered_to_string(~H"""
    <AgentCommsComponent.comms_feed
      stream={@stream}
      event_count={@event_count}
      id={@id}
    />
    """)
  end
end
