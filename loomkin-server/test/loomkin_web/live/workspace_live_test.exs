defmodule LoomkinWeb.WorkspaceLiveTest do
  @moduledoc """
  Integration tests verifying all extracted components are properly wired
  into WorkspaceLive and the module compiles correctly.

  Includes both fast module-level smoke tests and a real LiveView mount test
  that verifies extracted components render in the DOM.
  """
  use LoomkinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "live mount and component rendering" do
    test "mounting workspace renders all extracted components", %{conn: conn} do
      {:ok, _view, html} =
        case live(conn, "/sessions/new") do
          {:ok, view, html} ->
            {:ok, view, html}

          {:error, {:live_redirect, %{to: path}}} ->
            live(conn, path)
        end

      # CommandPaletteComponent renders its wrapper div
      assert html =~ "command-palette"

      # ComposerComponent renders the message input and send form
      assert html =~ "message-input"
      assert html =~ "send_message"

      # MissionControlPanelComponent renders the tab switcher (kin/comms)
      assert html =~ "switch_tab"

      # No inline defp render_ output should appear — all rendering is via components
      refute html =~ "render_agent_card"
      refute html =~ "render_comms_feed"
    end
  end

  describe "module compilation and component wiring" do
    test "workspace_live compiles successfully" do
      assert {:module, LoomkinWeb.WorkspaceLive} =
               Code.ensure_loaded(LoomkinWeb.WorkspaceLive)
    end

    test "workspace_live implements liveview callbacks" do
      assert {:module, LoomkinWeb.WorkspaceLive} =
               Code.ensure_loaded(LoomkinWeb.WorkspaceLive)

      # mount and render are defined but may be private via LiveView macros
      funs = LoomkinWeb.WorkspaceLive.__info__(:functions)
      assert {:handle_event, 3} in funs
      assert {:handle_info, 2} in funs
    end

    test "command palette component exists and is a live component" do
      assert {:module, LoomkinWeb.CommandPaletteComponent} =
               Code.ensure_loaded(LoomkinWeb.CommandPaletteComponent)

      assert function_exported?(LoomkinWeb.CommandPaletteComponent, :render, 1)
      assert function_exported?(LoomkinWeb.CommandPaletteComponent, :update, 2)
    end

    test "composer component exists and is a live component" do
      assert {:module, LoomkinWeb.ComposerComponent} =
               Code.ensure_loaded(LoomkinWeb.ComposerComponent)

      assert function_exported?(LoomkinWeb.ComposerComponent, :render, 1)
      assert function_exported?(LoomkinWeb.ComposerComponent, :update, 2)
    end

    test "mission control panel component exists and is a live component" do
      assert {:module, LoomkinWeb.MissionControlPanelComponent} =
               Code.ensure_loaded(LoomkinWeb.MissionControlPanelComponent)

      assert function_exported?(LoomkinWeb.MissionControlPanelComponent, :render, 1)
      assert function_exported?(LoomkinWeb.MissionControlPanelComponent, :update, 2)
    end

    test "workspace_live references core extracted components in source" do
      {:ok, source} =
        File.read("lib/loomkin_web/live/workspace_live.ex")

      assert source =~ "LoomkinWeb.CommandPaletteComponent"
      assert source =~ "LoomkinWeb.ComposerComponent"
      assert source =~ "LoomkinWeb.MissionControlPanelComponent"
      assert source =~ "LoomkinWeb.ContextInspectorComponent"
    end

    test "workspace_live has no inline defp render_ functions" do
      {:ok, source} =
        File.read("lib/loomkin_web/live/workspace_live.ex")

      # Should not contain any defp render_ function definitions
      refute Regex.match?(~r/defp render_\w+\(/, source)
    end

    test "workspace_live handles forwarded component events" do
      {:ok, source} =
        File.read("lib/loomkin_web/live/workspace_live.ex")

      assert source =~ "{:command_palette_action,"
      assert source =~ "{:composer_event,"
      assert source =~ "{:mission_control_event,"
    end
  end
end
