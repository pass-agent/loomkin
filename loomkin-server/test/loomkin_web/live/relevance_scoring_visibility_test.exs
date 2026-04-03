defmodule LoomkinWeb.RelevanceScoringVisibilityTest do
  @moduledoc "Tests for relevance scoring visibility — discovery events show recipient/filtered agents."

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]

  alias LoomkinWeb.AgentCommsComponent

  describe "discovery events with relevance metadata" do
    test "renders relevance details with recipients and filtered agents" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :discovery,
        agent: "researcher",
        content: "Found auth module pattern in lib/auth/",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{
          discovery_type: "discovery",
          relevance: %{
            recipients: [{"coder-1", 0.87}, {"researcher-2", 0.72}],
            skipped: [{"tester", 0.12}]
          }
        }
      }

      html = render_comms_feed([event])

      # Relevance badge on summary line
      assert html =~ ~s(data-testid="relevance-badge")
      assert html =~ "2 recipients"

      # Expanded relevance details
      assert html =~ ~s(data-testid="relevance-details")
      assert html =~ "Sent to:"
      assert html =~ "coder-1"
      assert html =~ "0.87"
      assert html =~ "researcher-2"
      assert html =~ "0.72"
      assert html =~ "Filtered:"
      assert html =~ "tester"
      assert html =~ "0.12"
    end

    test "discovery without relevance metadata shows plain content" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :discovery,
        agent: "researcher",
        content: "Found something interesting",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{}
      }

      html = render_comms_feed([event])

      assert html =~ "Found something interesting"
      refute html =~ ~s(data-testid="relevance-badge")
      refute html =~ ~s(data-testid="relevance-details")
    end

    test "discovery with empty recipients still shows details" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :discovery,
        agent: "researcher",
        content: "Discovery content",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{
          discovery_type: "discovery",
          relevance: %{
            recipients: [],
            skipped: [{"coder-1", 0.15}]
          }
        }
      }

      html = render_comms_feed([event])

      assert html =~ ~s(data-testid="relevance-details")
      assert html =~ "Filtered:"
      assert html =~ "coder-1"
      # The "Sent to:" section in the detail body should not render for empty recipients
      # (badge tooltip still contains it, but the detail div is hidden)
      refute html =~ ~s(<span class="text-zinc-500">Sent to:</span>)
    end

    test "discovery with recipients but no filtered agents" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :discovery,
        agent: "researcher",
        content: "Important finding",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{
          discovery_type: "discovery",
          relevance: %{
            recipients: [{"coder-1", 0.92}],
            skipped: []
          }
        }
      }

      html = render_comms_feed([event])

      assert html =~ "Sent to:"
      assert html =~ "coder-1"
      assert html =~ "0.92"
      refute html =~ "Filtered:"
    end

    test "relevance badge tooltip shows score breakdown" do
      event = %{
        id: Ecto.UUID.generate(),
        type: :discovery,
        agent: "researcher",
        content: "Finding",
        timestamp: DateTime.utc_now(),
        expanded: false,
        metadata: %{
          discovery_type: "discovery",
          relevance: %{
            recipients: [{"coder-1", 0.87}],
            skipped: [{"tester", 0.12}]
          }
        }
      }

      html = render_comms_feed([event])

      # Badge tooltip should contain score info
      assert html =~ "Sent to: coder-1 (0.87)"
      assert html =~ "Filtered: tester (0.12)"
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
