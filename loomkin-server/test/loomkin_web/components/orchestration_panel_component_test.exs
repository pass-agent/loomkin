defmodule LoomkinWeb.OrchestrationPanelComponentTest do
  @moduledoc """
  Verifies the sticky "current activity" panel that wraps each epic on
  `OrchestrationShowLive`. Tests exercise both isolated render (via
  `render_component/2`) and the end-to-end mount through the parent
  LiveView to ensure PubSub subscriptions don't blow up.
  """

  use LoomkinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Loomkin.Orchestration.Schema.Epic
  alias Loomkin.Repo

  setup :register_and_log_in_user

  defp make_epic(attrs) do
    base = %{
      id: Ecto.UUID.generate(),
      title: "implement greeter personalisation",
      spec: "x",
      status: :in_progress,
      current_phase: "research"
    }

    {:ok, epic} = Repo.insert(Epic.changeset(%Epic{}, Map.merge(base, attrs)))
    epic
  end

  describe "isolated render via render_component/2" do
    test "renders persona icon, name, role blurb, and action hints" do
      epic = make_epic(%{current_phase: "research"})

      html =
        render_component(LoomkinWeb.OrchestrationPanelComponent, %{
          id: "panel-" <> epic.id,
          epic: epic
        })

      # Persona for :research is the Researcher
      assert html =~ "Researcher"
      assert html =~ "gathers context"
      # Epic title shows in the body
      assert html =~ "implement greeter personalisation"
      # Status starts as monitoring (in_progress -> monitoring mapping)
      assert html =~ "monitoring"
      # Action hints present (disabled until r14)
      assert html =~ "pause"
      assert html =~ "cancel"
      assert html =~ "open dashboard"
    end

    test "renders the failed badge when epic.status is :failed" do
      epic = make_epic(%{status: :failed})

      html =
        render_component(LoomkinWeb.OrchestrationPanelComponent, %{
          id: "panel-" <> epic.id,
          epic: epic
        })

      assert html =~ "failed"
    end

    test "renders the escalated badge for :awaiting_human" do
      epic = make_epic(%{status: :awaiting_human})

      html =
        render_component(LoomkinWeb.OrchestrationPanelComponent, %{
          id: "panel-" <> epic.id,
          epic: epic
        })

      assert html =~ "escalated"
    end

    test "renders 9 progress dots regardless of current_phase" do
      epic = make_epic(%{current_phase: "plan"})

      html =
        render_component(LoomkinWeb.OrchestrationPanelComponent, %{
          id: "panel-" <> epic.id,
          epic: epic
        })

      # 9 rounded dots in the progress strip
      dots = Regex.scan(~r/class="block h-2\.5 w-2\.5 rounded-full"/, html)
      assert length(dots) == 9
    end

    test "is rendered inside the parent OrchestrationShowLive page", %{conn: conn} do
      epic = make_epic(%{})

      {:ok, _view, html} = live(conn, "/orchestration/" <> epic.id)

      # Component renders the testid wrapper
      assert html =~ "orchestration-epic-card"
      # And surfaces the persona for the current phase
      assert html =~ "Researcher"
    end
  end
end
