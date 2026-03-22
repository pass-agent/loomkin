defmodule LoomkinWeb.MissionControlPanelComponentTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @base_assigns %{
    id: "test-mc-panel",
    agent_cards: %{},
    concierge_card_names: [],
    worker_card_names: [],
    comms_event_count: 0,
    focused_agent: nil,
    inspector_mode: :auto_follow,
    kin_agents: [],
    cached_agents: [],
    active_team_id: "team-1",
    comms_stream: nil,
    leader_approval_pending: nil,
    collab_health: nil
  }

  test "renders waiting state when no agents" do
    html = render_component(LoomkinWeb.MissionControlPanelComponent, @base_assigns)
    assert html =~ "Your concierge is ready"
    assert html =~ "Send a message below and your kin team will assemble to help."
  end

  test "renders kin section header" do
    html = render_component(LoomkinWeb.MissionControlPanelComponent, @base_assigns)
    assert html =~ "Kin"
  end

  defp build_card(name, overrides \\ %{}) do
    Map.merge(
      %{
        name: name,
        content_type: :idle,
        role: :coder,
        status: :idle,
        model: nil,
        latest_content: nil,
        last_tool: nil,
        pending_question: nil,
        current_task: nil
      },
      overrides
    )
  end

  test "shows agent count badge" do
    assigns =
      Map.merge(@base_assigns, %{
        worker_card_names: ["alice"],
        agent_cards: %{"alice" => build_card("alice")}
      })

    html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
    # The badge showing the count of worker agents
    assert html =~ "1"
  end

  test "renders dormant kin ghost cards" do
    kin = %{
      id: "k1",
      name: "rex",
      display_name: "Rex",
      enabled: true,
      potency: 80,
      role: :coder
    }

    assigns =
      Map.merge(@base_assigns, %{
        kin_agents: [kin],
        cached_agents: []
      })

    html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
    assert html =~ "Rex"
  end

  test "renders focused agent back button when pinned" do
    assigns =
      Map.merge(@base_assigns, %{
        focused_agent: "alice",
        inspector_mode: :pinned,
        agent_cards: %{"alice" => build_card("alice")}
      })

    html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
    assert html =~ "All agents"
  end

  test "does not show focused card view when inspector_mode is auto_follow" do
    assigns =
      Map.merge(@base_assigns, %{
        focused_agent: "alice",
        inspector_mode: :auto_follow,
        agent_cards: %{"alice" => build_card("alice")}
      })

    html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
    refute html =~ "All agents"
  end

  describe "leader approval banner" do
    test "renders banner with question when leader_approval_pending is non-nil" do
      assigns =
        Map.merge(@base_assigns, %{
          leader_approval_pending: %{
            gate_id: "gate-123",
            question: "Should we proceed with the migration?",
            started_at: 1_700_000_000_000,
            timeout_ms: 60_000
          }
        })

      html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
      assert html =~ ~s(data-testid="leader-approval-banner")
      assert html =~ "Should we proceed with the migration?"
    end

    test "does not render banner when leader_approval_pending is nil" do
      html = render_component(LoomkinWeb.MissionControlPanelComponent, @base_assigns)
      refute html =~ ~s(data-testid="leader-approval-banner")
    end

    test "banner has CountdownTimer hook with deadline-at attribute" do
      started_at = 1_700_000_000_000
      timeout_ms = 60_000

      assigns =
        Map.merge(@base_assigns, %{
          leader_approval_pending: %{
            gate_id: "gate-123",
            question: "Proceed?",
            started_at: started_at,
            timeout_ms: timeout_ms
          }
        })

      html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
      assert html =~ ~s(phx-hook="CountdownTimer")
      assert html =~ ~s(data-deadline-at="#{started_at + timeout_ms}")
    end
  end

  describe "collaboration health indicator" do
    test "does not render health indicator when collab_health is nil" do
      html = render_component(LoomkinWeb.MissionControlPanelComponent, @base_assigns)
      refute html =~ ~s(data-testid="collab-health-indicator")
    end

    test "renders health indicator when collab_health is set" do
      assigns = Map.put(@base_assigns, :collab_health, 75)
      html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
      assert html =~ ~s(data-testid="collab-health-indicator")
      assert html =~ "75"
    end

    test "shows green bar for score >= 70" do
      assigns = Map.put(@base_assigns, :collab_health, 85)
      html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
      assert html =~ "bg-emerald-500"
      assert html =~ "text-emerald-400"
      assert html =~ ~s(width: 85%)
    end

    test "shows yellow bar for score 40-69" do
      assigns = Map.put(@base_assigns, :collab_health, 55)
      html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
      assert html =~ "bg-amber-400"
      assert html =~ "text-amber-400"
      assert html =~ ~s(width: 55%)
    end

    test "shows red bar for score < 40" do
      assigns = Map.put(@base_assigns, :collab_health, 20)
      html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
      assert html =~ "bg-red-500"
      assert html =~ "text-red-400"
      assert html =~ ~s(width: 20%)
    end

    test "tooltip shows score value" do
      assigns = Map.put(@base_assigns, :collab_health, 72)
      html = render_component(LoomkinWeb.MissionControlPanelComponent, assigns)
      assert html =~ "Collaboration Health: 72/100"
    end
  end
end
