defmodule LoomkinWeb.CommandPaletteComponentTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders nothing when closed" do
    html =
      render_component(LoomkinWeb.CommandPaletteComponent,
        id: "test-palette",
        command_palette_open: false,
        command_palette_query: "",
        command_palette_results: [],
        agents: []
      )

    refute html =~ "command-palette"
  end

  test "renders search input when open" do
    html =
      render_component(LoomkinWeb.CommandPaletteComponent,
        id: "test-palette",
        command_palette_open: true,
        command_palette_query: "",
        command_palette_results: [],
        agents: []
      )

    assert html =~ "Search agents, tabs, actions..."
  end

  test "shows no results message when results empty" do
    html =
      render_component(LoomkinWeb.CommandPaletteComponent,
        id: "test-palette",
        command_palette_open: true,
        command_palette_query: "",
        command_palette_results: [],
        agents: []
      )

    assert html =~ "No results found"
  end

  test "renders result items" do
    results = [%{type: "tab", label: "Files", value: "files", icon: nil, detail: "Inspector Tab"}]

    html =
      render_component(LoomkinWeb.CommandPaletteComponent,
        id: "test-palette",
        command_palette_open: true,
        command_palette_query: "",
        command_palette_results: results,
        agents: []
      )

    assert html =~ "Files"
  end
end
