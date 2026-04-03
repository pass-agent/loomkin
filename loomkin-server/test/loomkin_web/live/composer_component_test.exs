defmodule LoomkinWeb.ComposerComponentTest do
  use LoomkinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @base_assigns %{
    id: "test-composer",
    input_text: "",
    reply_target: nil,
    cached_agents: [],
    last_user_message: nil,
    queue_drawer: nil,
    scheduled_messages: [],
    agent_queues: %{},
    agent_cards: %{},
    active_team_id: "team-1",
    session_id: "sess-1",
    show_agent_picker: false,
    schedule_popover: false,
    schedule_delay_minutes: 5,
    status: :idle
  }

  test "renders message textarea" do
    html = render_component(LoomkinWeb.ComposerComponent, @base_assigns)
    assert html =~ "textarea" or html =~ "send_message"
  end

  test "renders reply indicator when reply_target is set" do
    assigns = Map.merge(@base_assigns, %{reply_target: %{agent: "alice", team_id: "t1"}})
    html = render_component(LoomkinWeb.ComposerComponent, assigns)
    assert html =~ "alice"
    assert html =~ "Replying"
  end

  test "renders last user message when present" do
    assigns = Map.merge(@base_assigns, %{last_user_message: %{to: "bob", text: "hello"}})
    html = render_component(LoomkinWeb.ComposerComponent, assigns)
    assert html =~ "bob"
    assert html =~ "hello"
  end

  test "does not render last user message when nil" do
    html = render_component(LoomkinWeb.ComposerComponent, @base_assigns)
    refute html =~ "&rarr;"
  end
end
