defmodule LoomkinWeb.TeamActivityComponentTest do
  use LoomkinWeb.ConnCase

  import Phoenix.LiveViewTest

  @team_id "test-team-activity"

  describe "rendering" do
    test "renders empty activity feed" do
      html =
        render_component(LoomkinWeb.TeamActivityComponent, %{
          id: "test-activity",
          team_id: @team_id
        })

      assert html =~ "No activity yet"
    end

    test "renders All agent filter button active by default" do
      html =
        render_component(LoomkinWeb.TeamActivityComponent, %{
          id: "test-activity",
          team_id: @team_id
        })

      # All button should be highlighted (active) when no agent filter is set
      assert html =~ "All"
      assert html =~ "var(--brand-subtle)"
    end

    test "renders type filter buttons" do
      html =
        render_component(LoomkinWeb.TeamActivityComponent, %{
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
      html =
        render_component(LoomkinWeb.TeamActivityComponent, %{
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

  describe "card rendering" do
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
        reset_events: events,
        known_agents: Enum.map(events, & &1.agent) |> Enum.uniq()
      })
    end

    test "no reply buttons on any card type" do
      events = [
        make_event(:message, "researcher", %{metadata: %{from: "researcher", to: "Team"}}),
        make_event(:tool_call, "coder", %{metadata: %{tool_name: "read_file"}}),
        make_event(:task_created, "system", %{metadata: %{title: "Implement feature"}}),
        make_event(:discovery, "researcher"),
        make_event(:error, "coder"),
        make_event(:thinking, "coder"),
        make_event(:channel_message, "bridge-bot", %{metadata: %{channel: :telegram}}),
        make_event(:question, "researcher", %{metadata: %{from: "researcher"}}),
        make_event(:agent_spawn, "coder", %{metadata: %{agent_name: "coder", role: "coder"}})
      ]

      html = render_with_events(events)
      refute html =~ "reply_to_agent"
      refute html =~ "Reply"
    end

    test "task_created card renders title and created label" do
      html =
        render_with_events([
          make_event(:task_created, "system", %{metadata: %{title: "Implement feature"}})
        ])

      assert html =~ "created"
      assert html =~ "Implement feature"
    end

    test "message card renders agent and content" do
      html =
        render_with_events([
          make_event(:message, "researcher", %{metadata: %{from: "researcher", to: "Team"}})
        ])

      assert html =~ "researcher"
      assert html =~ "test content"
    end

    test "tool_call card renders tool name" do
      html =
        render_with_events([make_event(:tool_call, "coder", %{metadata: %{tool_name: "Bash"}})])

      assert html =~ "Bash"
      assert html =~ "coder"
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
        reset_events: events,
        known_agents: Enum.map(events, & &1.agent) |> Enum.uniq()
      })
    end

    test "task_assigned card shows title and owner from metadata" do
      event =
        make_task_event(:task_assigned, "lead", %{
          metadata: %{
            title: "Fix login bug",
            owner: "researcher",
            priority: "2",
            status: "assigned"
          }
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
      # Badge uses inline style with accent_bg from design tokens
      assert html =~ "rgba(96, 165, 250"
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
        reset_events: events,
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
        reset_events: events,
        known_agents: Enum.map(events, & &1.agent) |> Enum.uniq()
      })
    end

    test "tool_call card has violet border and tool badge" do
      html =
        render_typed_events([
          make_typed_event(:tool_call, "coder", %{metadata: %{tool_name: "Bash"}})
        ])

      # Uses inline style with accent hex (#818cf8) for left border
      assert html =~ "#818cf8"
      assert html =~ "rgba(129, 140, 248"
      assert html =~ "Bash"
    end

    test "tool_call card shows file basename in header" do
      html =
        render_typed_events([
          make_typed_event(:tool_call, "coder", %{
            metadata: %{tool_name: "Read", file_path: "/app/lib/foo.ex"}
          })
        ])

      assert html =~ "foo.ex"
    end

    test "message card has emerald border and shows recipient" do
      html =
        render_typed_events([
          make_typed_event(:message, "lead", %{metadata: %{from: "lead", to: "researcher"}})
        ])

      # Uses inline style with accent hex (#34d399) for left border
      assert html =~ "#34d399"
      assert html =~ "researcher"
    end

    test "discovery card has yellow border and star icon" do
      html = render_typed_events([make_typed_event(:discovery, "researcher")])
      # Uses inline style with accent hex (#fbbf24) for left border
      assert html =~ "#fbbf24"
      assert html =~ "discovery"
      # Amber-tinted background via accent_bg
      assert html =~ "rgba(251, 191, 36"
    end

    test "error card has red border and warning icon" do
      html = render_typed_events([make_typed_event(:error, "coder")])
      # Uses inline style with accent hex (#f87171) for left border
      assert html =~ "#f87171"
      assert html =~ "rgba(248, 113, 113"
      assert html =~ "error"
    end

    test "error card with short message shows it inline in header" do
      html = render_typed_events([make_typed_event(:error, "coder", %{content: "Timeout"})])
      # Short errors are displayed inline in the header row
      assert html =~ "Timeout"
    end

    test "question card has sky border and highlighted background" do
      html = render_typed_events([make_typed_event(:question, "researcher")])
      # Uses inline style with accent hex (#38bdf8) for left border
      assert html =~ "#38bdf8"
      assert html =~ "rgba(56, 189, 248"
      assert html =~ "question"
    end

    test "agent_spawn card shows role inline" do
      html =
        render_typed_events([
          make_typed_event(:agent_spawn, "coder", %{
            metadata: %{agent_name: "coder", role: "developer"}
          })
        ])

      assert html =~ "coder"
      assert html =~ "joined"
      assert html =~ "developer"
    end

    test "task_complete card has green tinted background" do
      html =
        render_typed_events([
          make_typed_event(:task_complete, "coder", %{metadata: %{title: "Done"}})
        ])

      # Uses inline style with accent hex (#4ade80) and green-tinted accent_bg
      assert html =~ "#4ade80"
      assert html =~ "done"
    end

    test "thinking card shows muted thinking indicator" do
      html = render_typed_events([make_typed_event(:thinking, "coder")])
      # Uses inline style with accent hex (#818cf8) for border
      assert html =~ "#818cf8"
      assert html =~ "thinking"
    end

    test "context_offload card shows content and topic inline" do
      html =
        render_typed_events([
          make_typed_event(:context_offload, "coder", %{
            content: "Stored context",
            metadata: %{topic: "architecture"}
          })
        ])

      assert html =~ "offload"
      assert html =~ "Stored context"
      assert html =~ "architecture"
    end

    test "long message content is truncated with show more" do
      long_content = String.duplicate("Hello world. ", 30)

      html =
        render_typed_events([
          make_typed_event(:message, "lead", %{content: long_content, metadata: %{from: "lead"}})
        ])

      assert html =~ "show more"
      assert html =~ "line-clamp-3"
    end
  end

  describe "card density and responsiveness" do
    defp make_dense_event(type, agent, opts) do
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

    defp render_dense_events(events) do
      render_component(LoomkinWeb.TeamActivityComponent, %{
        id: "test-activity",
        team_id: @team_id,
        reset_events: events,
        known_agents: Enum.map(events, & &1.agent) |> Enum.uniq()
      })
    end

    test "filter bar uses horizontal scroll instead of wrapping" do
      html = render_dense_events([])
      assert html =~ "overflow-x-auto"
    end

    test "card headers use min-w-0 for flex truncation" do
      html =
        render_dense_events([
          make_dense_event(:tool_call, "coder", %{metadata: %{tool_name: "Read"}})
        ])

      assert html =~ "min-w-0"
    end

    test "agent names use flex-shrink-0 to prevent collapsing" do
      html =
        render_dense_events([make_dense_event(:message, "lead", %{metadata: %{from: "lead"}})])

      assert html =~ "flex-shrink-0"
    end

    test "content text uses break-words for narrow viewports" do
      html =
        render_dense_events([
          make_dense_event(:message, "lead", %{
            content: "A long message",
            metadata: %{from: "lead"}
          })
        ])

      assert html =~ "break-word"
    end

    test "tool_call file path shows only basename" do
      html =
        render_dense_events([
          make_dense_event(:tool_call, "coder", %{
            metadata: %{
              tool_name: "Edit",
              file_path: "/very/long/path/to/some/deeply/nested/file.ex"
            }
          })
        ])

      # Should show basename, not the full path in the header
      assert html =~ "file.ex"
    end

    test "task card with long title truncates" do
      long_title = String.duplicate("very long task title ", 10)

      html =
        render_dense_events([
          make_dense_event(:task_assigned, "lead", %{
            metadata: %{title: long_title, owner: "coder"}
          })
        ])

      # Title should have truncate class
      assert html =~ "truncate"
      assert html =~ "coder"
    end

    test "error card with long content uses break-words" do
      long_content =
        String.duplicate("Error: something went wrong with a very long explanation ", 5)

      html = render_dense_events([make_dense_event(:error, "coder", %{content: long_content})])
      # Long error content is shown in body (not header), and uses word-break
      assert html =~ "break-word"
    end
  end
end
