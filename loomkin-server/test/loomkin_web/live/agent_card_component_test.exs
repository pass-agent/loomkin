defmodule LoomkinWeb.Live.AgentCardComponentTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp base_card(overrides) do
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

  defp render_card(card_overrides) do
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
    test "renders force pause button when waiting_permission" do
      html = render_card(%{status: :waiting_permission, pause_queued: true})

      assert html =~ "force_pause_card_agent"
      assert html =~ "Cancel pending permission?"
    end

    test "renders waiting_permission status without force pause when not queued" do
      html = render_card(%{status: :waiting_permission, pause_queued: false})

      assert html =~ "Waiting for permission"
    end
  end

  describe "approval_pending" do
    test "renders approval_pending status dot correctly" do
      html = render_card(%{status: :approval_pending})

      # The approval_pending status dot must be violet, not amber
      # This test fails until Plan 04 updates the dot class in agent_card_component
      assert html =~ "bg-violet-500"
      assert html =~ "Awaiting approval"
    end

    test "approval panel renders when card has pending_approval assign" do
      # When the card has a pending_approval assign (gate_id, question, timeout_ms),
      # the expanded approval panel section should be visible with question text
      # and approve/deny action buttons.
      pending_approval = %{
        gate_id: "gate-abc123",
        question: "Should I deploy to production?",
        timeout_ms: 300_000,
        started_at: System.system_time(:millisecond)
      }

      html = render_card(%{status: :approval_pending, pending_approval: pending_approval})

      assert html =~ "Approval required"
      assert html =~ "Should I deploy to production?"
      assert html =~ "approve_card_agent"
      assert html =~ "deny_card_agent"
      assert html =~ "Approve"
      assert html =~ "Deny"
      assert html =~ "Approve w/ Context"
      assert html =~ "CountdownTimer"
    end

    test "card_state_class for :approval_pending uses agent-card-approval not agent-card-blocked" do
      html = render_card(%{status: :approval_pending})

      # Approval gate uses distinct purple accent class, not the blocked class
      # This test fails until Plan 04 updates card_state_class/2 in agent_card_component
      assert html =~ "agent-card-approval"
      refute html =~ "agent-card-blocked"
    end
  end

  describe "last-transition hint" do
    test "renders status label for current status" do
      html = render_card(%{status: :paused, previous_status: :working})

      assert html =~ "Paused"
    end

    test "renders status label without previous_status" do
      html = render_card(%{status: :paused})

      assert html =~ "Paused"
    end
  end
end
