defmodule Loomkin.WorkspaceTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Workspace

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Workspace.changeset(%Workspace{}, %{name: "my project"})
      assert changeset.valid?
    end

    test "invalid without name" do
      changeset = Workspace.changeset(%Workspace{}, %{})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts optional fields" do
      changeset =
        Workspace.changeset(%Workspace{}, %{
          name: "test",
          project_paths: ["/tmp/project"],
          team_id: "team-abc",
          status: :hibernated
        })

      assert changeset.valid?
    end

    test "defaults status to active" do
      {:ok, workspace} =
        %Workspace{}
        |> Workspace.changeset(%{name: "test"})
        |> Repo.insert()

      assert workspace.status == :active
    end

    test "defaults project_paths to empty list" do
      {:ok, workspace} =
        %Workspace{}
        |> Workspace.changeset(%{name: "test"})
        |> Repo.insert()

      assert workspace.project_paths == []
    end
  end
end
