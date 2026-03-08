defmodule LoomkinWeb.Live.AgentCardComponentTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp base_card(overrides \\ %{}) do
    defaults = %{
      name: "test-agent",
      status: :idle,
      role: :coder,
      content_type: nil,
      latest_content: nil,
      last_tool: nil,
      current_task: nil,
      pending_question: nil
    }

    Map.merge(defaults, overrides)
  end

  defp render_card(card_overrides \\ %{}) do
    card = base_card(card_overrides)

    render_component(LoomkinWeb.AgentCardComponent, %{
      id: "agent-card-#{card.name}",
      card: card,
      focused: false,
      team_id: "team-1",
      model: nil
    })
  end

  describe "status controls" do
    test "renders pause button for :working status" do
      html = render_card(%{status: :working})

      assert html =~ "pause_card_agent"
      assert html =~ "Pause test-agent"
    end

    test "renders force-pause button for :waiting_permission status" do
      html = render_card(%{status: :waiting_permission})

      assert html =~ "force_pause_card_agent"
      assert html =~ "Force pause test-agent"
      # Should also show pending tool label
      assert html =~ "permission"
    end

    test "renders steer button (not resume) for :paused status" do
      html = render_card(%{status: :paused})

      assert html =~ "steer_card_agent"
      refute html =~ "resume_card_agent"
      assert html =~ "Steer test-agent"
    end
  end

  describe "dual state indicator" do
    test "renders pause_queued badge when pause_queued is true" do
      html = render_card(%{status: :waiting_permission, pause_queued: true})

      assert html =~ "pause queued"
    end

    test "does not render pause_queued badge when pause_queued is false" do
      html = render_card(%{status: :waiting_permission, pause_queued: false})

      refute html =~ "pause queued"
    end
  end

  describe "approval_pending" do
    test "renders approval_pending status dot correctly" do
      html = render_card(%{status: :approval_pending})

      # The approval_pending status should render with the amber dot class
      assert html =~ "bg-amber-400"
      assert html =~ "Awaiting approval"
    end
  end

  describe "last-transition hint" do
    test "renders previous_status hint" do
      html = render_card(%{status: :paused, previous_status: :working})

      assert html =~ "from:"
      assert html =~ "working"
    end

    test "does not render hint when no previous_status" do
      html = render_card(%{status: :paused})

      refute html =~ "from:"
    end
  end
end
