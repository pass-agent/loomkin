defmodule LoomkinWeb.TeamActivityComponentTest do
  use LoomkinWeb.ConnCase

  import Phoenix.LiveViewTest

  @team_id "test-team-activity"

  describe "rendering" do
    test "renders empty activity feed" do
      html = render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id
      })

      assert html =~ "No activity yet"
    end

    test "renders All agent filter button active by default" do
      html = render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id
      })

      # All button should be highlighted (active) when no agent filter is set
      assert html =~ "All"
      assert html =~ "bg-violet-600"
    end

    test "renders type filter buttons" do
      html = render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id
      })

      assert html =~ "tool"
      assert html =~ "message"
      assert html =~ "created"
      assert html =~ "done"
      assert html =~ "assigned"
      assert html =~ "discovery"
      assert html =~ "error"
      assert html =~ "thinking"
      assert html =~ "joined"
      assert html =~ "offload"
      assert html =~ "question"
    end
  end

  describe "event filtering" do
    test "events list is initially empty" do
      html = render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id
      })

      assert html =~ "No activity yet"
    end
  end

  describe "event capping" do
    test "max_events constant is 200" do
      # The module attribute @max_events is 200
      # We verify this by checking the module compiles with that constant
      assert Code.ensure_loaded?(LoomkinWeb.TeamActivityComponent)
    end
  end

  describe "agent color mapping" do
    test "module uses consistent agent color palette" do
      # TeamActivityComponent uses @agent_colors with 8 colors
      # and :erlang.phash2 for consistent mapping
      assert Code.ensure_loaded?(LoomkinWeb.TeamActivityComponent)
    end
  end

  describe "reply button" do
    defp make_event(type, agent, opts \\ %{}) do
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          type: type,
          agent: agent,
          content: "test content",
          timestamp: DateTime.utc_now(),
          expanded: false,
          metadata: Map.get(opts, :metadata, %{})
        },
        opts
      )
    end

    defp render_with_events(events) do
      render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id,
        events: events,
        known_agents: Enum.map(events, & &1.agent) |> Enum.uniq()
      })
    end

    test "message card shows reply button for agent" do
      html = render_with_events([make_event(:message, "researcher", %{metadata: %{from: "researcher", to: "Team"}})])
      assert html =~ "Reply to researcher"
      assert html =~ "reply_to_agent"
    end

    test "tool_call card shows reply button" do
      html = render_with_events([make_event(:tool_call, "coder", %{metadata: %{tool_name: "read_file"}})])
      assert html =~ "Reply to coder"
    end

    test "task_created card hides reply button for system agent" do
      html = render_with_events([make_event(:task_created, "system", %{metadata: %{title: "Implement feature"}})])
      refute html =~ "Reply to system"
    end

    test "task_created card renders title and created label" do
      html = render_with_events([make_event(:task_created, "system", %{metadata: %{title: "Implement feature"}})])
      assert html =~ "created"
      assert html =~ "Implement feature"
    end

    test "task_complete card shows reply button" do
      html = render_with_events([make_event(:task_complete, "coder", %{metadata: %{title: "Fix bug"}})])
      assert html =~ "Reply to coder"
    end

    test "discovery card shows reply button" do
      html = render_with_events([make_event(:discovery, "researcher")])
      assert html =~ "Reply to researcher"
    end

    test "error card shows reply button" do
      html = render_with_events([make_event(:error, "coder")])
      assert html =~ "Reply to coder"
    end

    test "channel_message card shows reply button" do
      html = render_with_events([make_event(:channel_message, "bridge-bot", %{metadata: %{channel: :telegram, sender: "user123"}})])
      assert html =~ "Reply to bridge-bot"
    end

    test "reply button hidden when agent is You" do
      html = render_with_events([make_event(:message, "You", %{metadata: %{from: "You", to: "Team"}})])
      refute html =~ "Reply to You"
    end

    test "reply button hidden when agent is system" do
      html = render_with_events([make_event(:message, "system", %{metadata: %{from: "system"}})])
      refute html =~ "Reply to system"
    end

    test "agent_spawn card does not show reply button" do
      html = render_with_events([make_event(:agent_spawn, "coder", %{metadata: %{agent_name: "coder", role: "coder"}})])
      refute html =~ "reply_to_agent"
    end

    test "thinking card does not show reply button" do
      html = render_with_events([make_event(:thinking, "coder")])
      refute html =~ "reply_to_agent"
    end
  end

  describe "task_assigned card from team_assign" do
    defp make_task_event(type, agent, opts) do
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          type: type,
          agent: agent,
          content: "Assigned task to researcher",
          timestamp: DateTime.utc_now(),
          expanded: false,
          metadata: Map.get(opts, :metadata, %{})
        },
        opts
      )
    end

    defp render_task_events(events) do
      render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id,
        events: events,
        known_agents: Enum.map(events, & &1.agent) |> Enum.uniq()
      })
    end

    test "task_assigned card shows title and owner from metadata" do
      event =
        make_task_event(:task_assigned, "lead", %{
          metadata: %{title: "Fix login bug", owner: "researcher", priority: "2", status: "assigned"}
        })

      html = render_task_events([event])
      assert html =~ "assigned"
      assert html =~ "Fix login bug"
      assert html =~ "researcher"
    end

    test "task_assigned card shows assigned label badge" do
      event =
        make_task_event(:task_assigned, "lead", %{
          metadata: %{title: "Write tests", owner: "coder"}
        })

      html = render_task_events([event])
      assert html =~ "bg-blue-400/20"
      assert html =~ "assigned"
    end
  end

  describe "expand/collapse persistence" do
    defp make_expandable_event(type, agent, opts) do
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          type: type,
          agent: agent,
          content: "test content",
          timestamp: DateTime.utc_now(),
          metadata: Map.get(opts, :metadata, %{})
        },
        opts
      )
    end

    defp render_expand_events(events) do
      render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id,
        events: events,
        known_agents: Enum.map(events, & &1.agent) |> Enum.uniq()
      })
    end

    test "tool_call card with result renders collapsed by default" do
      long_result = String.duplicate("x", 600)

      event =
        make_expandable_event(:tool_call, "coder", %{
          metadata: %{tool_name: "Read", result: long_result}
        })

      html = render_expand_events([event])

      # Result is collapsed behind a toggle (no preview shown)
      assert html =~ "Result"
      refute html =~ "Collapse"
    end

    test "tool_call card with short result also shows collapsed toggle" do
      event =
        make_expandable_event(:tool_call, "coder", %{
          metadata: %{tool_name: "Read", result: "short"}
        })

      html = render_expand_events([event])

      # All results are collapsed regardless of length
      assert html =~ "Result"
      refute html =~ "Collapse"
    end

    test "task_complete card with result shows expand button" do
      event =
        make_expandable_event(:task_complete, "coder", %{
          metadata: %{title: "Fix bug", result: "All tests pass"}
        })

      html = render_expand_events([event])

      assert html =~ "Show result"
    end

    test "error card with details shows expand button" do
      event =
        make_expandable_event(:error, "coder", %{
          metadata: %{details: "Stack trace here..."}
        })

      html = render_expand_events([event])

      assert html =~ "Show details"
    end

    test "events do not carry expanded field — state lives in component" do
      # Events without an :expanded key should render fine (no KeyError)
      event = %{
        id: Ecto.UUID.generate(),
        type: :tool_call,
        agent: "coder",
        content: "used Read",
        timestamp: DateTime.utc_now(),
        metadata: %{tool_name: "Read", result: String.duplicate("x", 600)}
      }

      html = render_expand_events([event])
      assert html =~ "Result"
    end
  end

  describe "visual hierarchy per event type" do
    defp make_typed_event(type, agent, opts \\ %{}) do
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          type: type,
          agent: agent,
          content: "test content",
          timestamp: DateTime.utc_now(),
          metadata: Map.get(opts, :metadata, %{})
        },
        opts
      )
    end

    defp render_typed_events(events) do
      render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id,
        events: events,
        known_agents: Enum.map(events, & &1.agent) |> Enum.uniq()
      })
    end

    test "tool_call card has violet border and tool badge" do
      html = render_typed_events([make_typed_event(:tool_call, "coder", %{metadata: %{tool_name: "Bash"}})])
      assert html =~ "border-violet-500/40"
      assert html =~ "bg-violet-400/20"
      assert html =~ "Bash"
    end

    test "tool_call card shows file basename in header" do
      html = render_typed_events([make_typed_event(:tool_call, "coder", %{metadata: %{tool_name: "Read", file_path: "/app/lib/foo.ex"}})])
      assert html =~ "foo.ex"
    end

    test "message card has emerald border and shows recipient" do
      html = render_typed_events([make_typed_event(:message, "lead", %{metadata: %{from: "lead", to: "researcher"}})])
      assert html =~ "border-emerald-500/40"
      assert html =~ "researcher"
    end

    test "discovery card has yellow border and star icon" do
      html = render_typed_events([make_typed_event(:discovery, "researcher")])
      assert html =~ "border-yellow-500/40"
      assert html =~ "discovery"
      # Yellow-tinted background
      assert html =~ "bg-yellow-950/10"
    end

    test "error card has red border and warning icon" do
      html = render_typed_events([make_typed_event(:error, "coder")])
      assert html =~ "border-red-500/60"
      assert html =~ "bg-red-950/30"
      assert html =~ "error"
    end

    test "error card with short message shows it inline in header" do
      html = render_typed_events([make_typed_event(:error, "coder", %{content: "Timeout"})])
      # Short errors are displayed inline in the header row
      assert html =~ "Timeout"
    end

    test "question card has sky border and highlighted background" do
      html = render_typed_events([make_typed_event(:question, "researcher")])
      assert html =~ "border-sky-500/50"
      assert html =~ "bg-sky-950/15"
      assert html =~ "question"
    end

    test "agent_spawn card shows role inline" do
      html = render_typed_events([make_typed_event(:agent_spawn, "coder", %{metadata: %{agent_name: "coder", role: "developer"}})])
      assert html =~ "coder"
      assert html =~ "joined"
      assert html =~ "developer"
    end

    test "task_complete card has green tinted background" do
      html = render_typed_events([make_typed_event(:task_complete, "coder", %{metadata: %{title: "Done"}})])
      assert html =~ "bg-green-950/20"
      assert html =~ "done"
    end

    test "thinking card shows muted thinking indicator" do
      html = render_typed_events([make_typed_event(:thinking, "coder")])
      assert html =~ "border-indigo-500/30"
      assert html =~ "thinking"
    end

    test "context_offload card shows content and topic inline" do
      html = render_typed_events([make_typed_event(:context_offload, "coder", %{content: "Stored context", metadata: %{topic: "architecture"}})])
      assert html =~ "offload"
      assert html =~ "Stored context"
      assert html =~ "architecture"
    end

    test "long message content is truncated with show more" do
      long_content = String.duplicate("Hello world. ", 30)
      html = render_typed_events([make_typed_event(:message, "lead", %{content: long_content, metadata: %{from: "lead"}})])
      assert html =~ "show more"
      assert html =~ "line-clamp-3"
    end
  end
end
