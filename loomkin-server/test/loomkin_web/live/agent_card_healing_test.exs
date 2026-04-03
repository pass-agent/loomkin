defmodule LoomkinWeb.Live.AgentCardHealingTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LoomkinWeb.AgentCardComponent

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

    render_component(AgentCardComponent, %{
      id: "agent-card-#{card.name}",
      card: card,
      focused: false,
      team_id: "team-1",
      model: nil
    })
  end

  describe "suspended_healing status" do
    test "renders amber status dot with pulse animation" do
      html = render_card(%{status: :suspended_healing})

      assert html =~ "bg-amber-400"
      assert html =~ "animate-pulse"
    end

    test "renders 'Healing...' status label" do
      html = render_card(%{status: :suspended_healing})

      assert html =~ "Healing..."
    end

    test "renders amber status text" do
      html = render_card(%{status: :suspended_healing})

      assert html =~ "text-amber-400"
    end

    test "applies agent-card-healing card state class" do
      html = render_card(%{status: :suspended_healing})

      assert html =~ "agent-card-healing"
    end

    test "applies healing border style" do
      html = render_card(%{status: :suspended_healing})

      assert html =~ "border-amber-500/20"
    end
  end

  describe "healing indicator panel" do
    test "renders healing panel when status is :suspended_healing" do
      html = render_card(%{status: :suspended_healing})

      assert html =~ "Self-healing"
    end

    test "does not render healing panel for other statuses" do
      html = render_card(%{status: :working})

      refute html =~ "Self-healing"
    end

    test "renders diagnosing phase label by default" do
      html = render_card(%{status: :suspended_healing})

      assert html =~ "Diagnosing..."
    end

    test "renders fixing phase label" do
      html = render_card(%{status: :suspended_healing, healing_phase: :fixing})

      assert html =~ "Applying fix..."
    end

    test "renders confirming phase label" do
      html = render_card(%{status: :suspended_healing, healing_phase: :confirming})

      assert html =~ "Verifying..."
    end

    test "renders error category when present" do
      html =
        render_card(%{
          status: :suspended_healing,
          healing_error_category: "compile_error"
        })

      assert html =~ "compile_error"
    end
  end

  describe "status helper test delegates" do
    test "status_dot_class for :suspended_healing" do
      assert AgentCardComponent.status_dot_class_for_test(:suspended_healing) =~ "bg-amber-400"
      assert AgentCardComponent.status_dot_class_for_test(:suspended_healing) =~ "animate-pulse"
    end

    test "status_label for :suspended_healing" do
      assert AgentCardComponent.status_label_for_test(:suspended_healing) == "Healing..."
    end

    test "card_state_class for :suspended_healing" do
      assert AgentCardComponent.card_state_class_for_test(nil, :suspended_healing) ==
               "agent-card-healing"
    end
  end
end
