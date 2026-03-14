defmodule LoomkinWeb.SettingsLiveTest do
  use LoomkinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    # Reset config to defaults so ETS pollution from other tests
    # (e.g., config_test writing agents.max_iterations = 50) doesn't
    # corrupt original_values in mount.
    Loomkin.Config.load(System.tmp_dir!())
    :ok
  end

  describe "mount" do
    test "renders settings page with tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Settings"
      assert html =~ "Agents"
      assert html =~ "Budgets"
      assert html =~ "Healing"
      assert html =~ "Intelligence"
      assert html =~ "Safety"
    end

    test "shows back to workspace link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Back to Workspace"
    end

    test "renders agents tab by default with settings", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Team Structure"
      assert html =~ "Execution Limits"
      assert html =~ "Max loop iterations"
      assert html =~ "Orchestrator mode"
    end
  end

  describe "tab switching" do
    test "switches to budgets tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html = view |> element("button", "Budgets") |> render_click()

      assert html =~ "Team &amp; Agent Budgets"
      assert html =~ "Team budget"
    end

    test "switches to healing tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html = view |> element("button", "Healing") |> render_click()

      assert html =~ "Global Healing Controls"
      assert html =~ "Healing budget"
    end

    test "switches to intelligence tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html = view |> element("button", "Intelligence") |> render_click()

      assert html =~ "Context Window"
      assert html =~ "Decision Graph"
    end

    test "switches to safety tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html = view |> element("button", "Safety") |> render_click()

      assert html =~ "Auto-approved tools"
      assert html =~ "Shell Allowlist"
    end
  end

  describe "settings modification" do
    test "changing a number setting shows dirty indicator", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html =
        render_change(view, "update_setting", %{
          "agents.max_iterations" => "50",
          "_target" => ["agents.max_iterations"]
        })

      assert html =~ "1 setting changed"
      assert html =~ "Save changes"
    end

    test "toggling a boolean updates the value", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html =
        render_click(view, "update_setting", %{
          "key" => "teams.orchestrator_mode",
          "value" => "false"
        })

      assert html =~ "1 setting changed"
    end

    test "discard changes restores original values", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_change(view, "update_setting", %{
        "agents.max_iterations" => "50",
        "_target" => ["agents.max_iterations"]
      })

      html = render_click(view, "discard_changes")

      refute html =~ "setting changed"
      refute html =~ "Save changes"
    end

    test "reset_setting restores default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      render_change(view, "update_setting", %{
        "agents.max_iterations" => "50",
        "_target" => ["agents.max_iterations"]
      })

      html = render_click(view, "reset_setting", %{"key" => "agents.max_iterations"})

      refute html =~ "setting changed"
    end
  end

  describe "validation" do
    test "shows error for out-of-range number", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html =
        render_change(view, "update_setting", %{
          "agents.max_iterations" => "200",
          "_target" => ["agents.max_iterations"]
        })

      assert html =~ "must be between"
    end
  end
end
