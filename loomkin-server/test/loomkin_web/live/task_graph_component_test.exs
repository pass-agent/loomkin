defmodule LoomkinWeb.TaskGraphComponentTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Loomkin.Schemas.TeamTask
  alias Loomkin.Schemas.TeamTaskDep

  defp make_task(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      team_id: "team-1",
      title: "Test task",
      description: "A test task",
      status: :pending,
      owner: nil,
      priority: 3,
      result: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(TeamTask, Map.merge(defaults, attrs))
  end

  defp make_dep(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      dep_type: :blocks,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(TeamTaskDep, Map.merge(defaults, attrs))
  end

  describe "task node rendering" do
    test "renders task nodes with title, status indicator, and agent name" do
      task =
        make_task(%{
          title: "Build widget",
          status: :in_progress,
          owner: "alice"
        })

      html =
        render_component(LoomkinWeb.TaskGraphComponent, %{
          id: "test-graph",
          session_id: "sess-1",
          team_id: "team-1",
          tasks_override: [task],
          deps_override: []
        })

      assert html =~ "Build widget"
      assert html =~ "alice"
      # Status indicator color for in_progress (amber)
      assert html =~ "#fbbf24"
    end

    test "renders empty state when no tasks" do
      html =
        render_component(LoomkinWeb.TaskGraphComponent, %{
          id: "test-graph",
          session_id: "sess-1",
          team_id: "team-1",
          tasks_override: [],
          deps_override: []
        })

      assert html =~ "No tasks yet"
    end
  end

  describe "edge rendering" do
    test "blocking dependencies render as solid edges" do
      t1 = make_task(%{title: "Task A", status: :completed})
      t2 = make_task(%{title: "Task B", status: :pending})
      dep = make_dep(%{task_id: t2.id, depends_on_id: t1.id, dep_type: :blocks})

      html =
        render_component(LoomkinWeb.TaskGraphComponent, %{
          id: "test-graph",
          session_id: "sess-1",
          team_id: "team-1",
          tasks_override: [t1, t2],
          deps_override: [dep]
        })

      # Blocking edges should NOT have stroke-dasharray (solid lines)
      # The path element for blocking deps should exist
      assert html =~ "<path"
      refute html =~ "stroke-dasharray=\"6,4\""
    end

    test "informing dependencies render as dashed edges" do
      t1 = make_task(%{title: "Task A", status: :completed})
      t2 = make_task(%{title: "Task B", status: :pending})
      dep = make_dep(%{task_id: t2.id, depends_on_id: t1.id, dep_type: :informs})

      html =
        render_component(LoomkinWeb.TaskGraphComponent, %{
          id: "test-graph",
          session_id: "sess-1",
          team_id: "team-1",
          tasks_override: [t1, t2],
          deps_override: [dep]
        })

      assert html =~ "stroke-dasharray=\"6,4\""
    end
  end

  describe "status colors" do
    test "maps task status to correct node colors" do
      statuses_and_colors = [
        {:pending, "#9ca3af"},
        {:assigned, "#60a5fa"},
        {:in_progress, "#fbbf24"},
        {:completed, "#4ade80"},
        {:failed, "#f87171"}
      ]

      for {status, expected_color} <- statuses_and_colors do
        task = make_task(%{title: "Status test", status: status})

        html =
          render_component(LoomkinWeb.TaskGraphComponent, %{
            id: "test-graph",
            session_id: "sess-1",
            team_id: "team-1",
            tasks_override: [task],
            deps_override: []
          })

        assert html =~ expected_color,
               "Expected color #{expected_color} for status #{status}"
      end
    end
  end

  describe "detail panel" do
    test "clicking a task node shows detail panel with description, owner, and result" do
      task =
        make_task(%{
          title: "Detailed task",
          description: "This is a detailed description",
          status: :completed,
          owner: "bob",
          result: "Successfully completed"
        })

      html =
        render_component(LoomkinWeb.TaskGraphComponent, %{
          id: "test-graph",
          session_id: "sess-1",
          team_id: "team-1",
          tasks_override: [task],
          deps_override: [],
          selected_node_id: task.id
        })

      assert html =~ "Detailed task"
      assert html =~ "This is a detailed description"
      assert html =~ "bob"
      assert html =~ "Successfully completed"
    end
  end

  describe "critical path" do
    test "critical path edges have emphasized styling" do
      t1 = make_task(%{title: "Root", status: :pending})
      t2 = make_task(%{title: "Middle", status: :pending})
      t3 = make_task(%{title: "Leaf", status: :pending})

      deps = [
        make_dep(%{task_id: t2.id, depends_on_id: t1.id, dep_type: :blocks}),
        make_dep(%{task_id: t3.id, depends_on_id: t2.id, dep_type: :blocks})
      ]

      html =
        render_component(LoomkinWeb.TaskGraphComponent, %{
          id: "test-graph",
          session_id: "sess-1",
          team_id: "team-1",
          tasks_override: [t1, t2, t3],
          deps_override: deps
        })

      # Critical path edges should have thicker stroke (3) and amber color
      assert html =~ "stroke-width=\"3\""
      assert html =~ "#f59e0b"
    end
  end
end
