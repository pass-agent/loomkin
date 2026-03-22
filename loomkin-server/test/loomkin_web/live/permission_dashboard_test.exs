defmodule LoomkinWeb.PermissionDashboardComponentTest do
  use LoomkinWeb.ConnCase

  import Phoenix.LiveViewTest

  defp make_request(overrides \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        tool_name: "file_write",
        tool_path: "/lib/foo.ex",
        source: {:agent, "team-1", "coder-1"},
        agent_name: "coder-1",
        team_id: "team-1",
        category: :write,
        requested_at: DateTime.utc_now()
      },
      overrides
    )
  end

  describe "rendering" do
    test "renders pending permissions list" do
      requests = [
        make_request(%{agent_name: "coder-1", tool_name: "file_write"}),
        make_request(%{agent_name: "researcher-1", tool_name: "shell", category: :execute})
      ]

      html =
        render_component(LoomkinWeb.PermissionDashboardComponent, %{
          id: "permission-dashboard",
          pending_permissions: requests
        })

      assert html =~ "Pending Approvals"
      assert html =~ "coder-1"
      assert html =~ "researcher-1"
      assert html =~ "file_write"
      assert html =~ "shell"
    end

    test "renders badge count" do
      requests = [make_request(), make_request(), make_request()]

      html =
        render_component(LoomkinWeb.PermissionDashboardComponent, %{
          id: "permission-dashboard",
          pending_permissions: requests
        })

      assert html =~ "3"
    end

    test "pins execute requests to top" do
      read_req =
        make_request(%{
          tool_name: "file_read",
          category: :read,
          requested_at: DateTime.utc_now() |> DateTime.add(-10, :second)
        })

      exec_req =
        make_request(%{
          tool_name: "shell",
          category: :execute,
          requested_at: DateTime.utc_now()
        })

      html =
        render_component(LoomkinWeb.PermissionDashboardComponent, %{
          id: "permission-dashboard",
          pending_permissions: [read_req, exec_req]
        })

      # Execute should appear before read in the rendered output
      shell_pos = :binary.match(html, "shell") |> elem(0)
      read_pos = :binary.match(html, "file_read") |> elem(0)
      assert shell_pos < read_pos
    end

    test "shows batch action buttons" do
      requests = [
        make_request(%{agent_name: "coder-1", category: :read, tool_name: "file_read"}),
        make_request(%{agent_name: "coder-1", category: :write})
      ]

      html =
        render_component(LoomkinWeb.PermissionDashboardComponent, %{
          id: "permission-dashboard",
          pending_permissions: requests
        })

      assert html =~ "Approve All Reads"
      assert html =~ "Approve coder-1"
      assert html =~ "Deny All"
    end

    test "shows action buttons per request" do
      html =
        render_component(LoomkinWeb.PermissionDashboardComponent, %{
          id: "permission-dashboard",
          pending_permissions: [make_request()]
        })

      assert html =~ "Deny"
      assert html =~ "Once"
      assert html =~ "Always"
    end

    test "truncates long paths" do
      long_path = "/very/long/deeply/nested/path/that/goes/on/and/on/file.ex"

      html =
        render_component(LoomkinWeb.PermissionDashboardComponent, %{
          id: "permission-dashboard",
          pending_permissions: [make_request(%{tool_path: long_path})]
        })

      assert html =~ "..."
    end

    test "color-codes categories" do
      requests = [
        make_request(%{category: :read, tool_name: "file_read"}),
        make_request(%{category: :write, tool_name: "file_write"}),
        make_request(%{category: :execute, tool_name: "shell"})
      ]

      html =
        render_component(LoomkinWeb.PermissionDashboardComponent, %{
          id: "permission-dashboard",
          pending_permissions: requests
        })

      assert html =~ "bg-emerald-400"
      assert html =~ "bg-amber-400"
      assert html =~ "bg-red-400"
    end
  end
end
