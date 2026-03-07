defmodule LoomkinWeb.SidebarPanelComponentTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @base_assigns %{
    id: "test-sidebar",
    active_tab: :files,
    selected_file: nil,
    file_content: nil,
    diffs: [],
    file_tree_version: 0,
    session_id: "sess-1",
    active_team_id: "team-1",
    explorer_path: "/tmp",
    project_path: "/tmp"
  }

  test "renders tab bar with files, diff, graph tabs" do
    html = render_component(LoomkinWeb.SidebarPanelComponent, @base_assigns)
    assert html =~ "Files"
    assert html =~ "Diff"
    assert html =~ "Graph"
  end

  test "active tab has brand styling" do
    html = render_component(LoomkinWeb.SidebarPanelComponent, @base_assigns)
    assert html =~ "text-brand"
  end

  test "renders file tree for files tab" do
    html = render_component(LoomkinWeb.SidebarPanelComponent, @base_assigns)
    # FileTreeComponent renders an Explorer header
    assert html =~ "Explorer"
  end

  test "renders diff component for diff tab" do
    html =
      render_component(LoomkinWeb.SidebarPanelComponent, %{@base_assigns | active_tab: :diff})

    # DiffComponent renders a Changes header
    assert html =~ "Changes"
  end

  test "renders graph component for graph tab" do
    html =
      render_component(LoomkinWeb.SidebarPanelComponent, %{@base_assigns | active_tab: :graph})

    # DecisionGraphComponent renders a Decision Graph header
    assert html =~ "Decision Graph"
  end

  test "shows file preview when selected_file is set" do
    html =
      render_component(LoomkinWeb.SidebarPanelComponent, %{
        @base_assigns
        | active_tab: :files,
          selected_file: "lib/foo.ex",
          file_content: "defmodule Foo do\nend"
      })

    assert html =~ "lib/foo.ex"
  end
end
