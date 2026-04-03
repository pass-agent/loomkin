defmodule Loomkin.Channels.BindingTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Channels.{Binding, Bindings}

  describe "Binding schema" do
    test "valid changeset with required fields" do
      changeset =
        Binding.changeset(%Binding{}, %{
          channel: :telegram,
          channel_id: "chat_123",
          team_id: "team-abc"
        })

      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Binding.changeset(%Binding{}, %{})
      refute changeset.valid?
      assert %{channel: _, channel_id: _, team_id: _} = errors_on(changeset)
    end

    test "accepts optional fields" do
      changeset =
        Binding.changeset(%Binding{}, %{
          channel: :discord,
          channel_id: "ch_456",
          team_id: "team-xyz",
          user_id: "user-1",
          config: %{"notifications" => "all"},
          active: false
        })

      assert changeset.valid?
      assert get_change(changeset, :user_id) == "user-1"
      assert get_change(changeset, :config) == %{"notifications" => "all"}
      assert get_change(changeset, :active) == false
    end

    test "defaults active to true" do
      {:ok, binding} =
        Bindings.create_binding(%{
          channel: :telegram,
          channel_id: "default-active-test",
          team_id: "team-1"
        })

      assert binding.active == true
    end
  end

  describe "Bindings.create_binding/1" do
    test "creates a binding successfully" do
      assert {:ok, binding} =
               Bindings.create_binding(%{
                 channel: :telegram,
                 channel_id: "create-test-1",
                 team_id: "team-create"
               })

      assert binding.id != nil
      assert binding.channel == :telegram
      assert binding.channel_id == "create-test-1"
      assert binding.team_id == "team-create"
    end

    test "returns error for invalid data" do
      assert {:error, changeset} = Bindings.create_binding(%{channel: :telegram})
      refute changeset.valid?
    end
  end

  describe "Bindings.get_binding/1" do
    test "returns binding by ID" do
      {:ok, created} =
        Bindings.create_binding(%{
          channel: :telegram,
          channel_id: "get-test-1",
          team_id: "team-get"
        })

      assert found = Bindings.get_binding(created.id)
      assert found.id == created.id
      assert found.channel_id == "get-test-1"
    end

    test "returns nil for unknown ID" do
      assert Bindings.get_binding(Ecto.UUID.generate()) == nil
    end
  end

  describe "Bindings.get_by_channel/2" do
    test "looks up active binding by channel and channel_id" do
      {:ok, _} =
        Bindings.create_binding(%{
          channel: :telegram,
          channel_id: "lookup-test-1",
          team_id: "team-lookup"
        })

      assert found = Bindings.get_by_channel(:telegram, "lookup-test-1")
      assert found.team_id == "team-lookup"
    end

    test "returns nil for inactive binding" do
      {:ok, binding} =
        Bindings.create_binding(%{
          channel: :telegram,
          channel_id: "inactive-test",
          team_id: "team-inactive"
        })

      Bindings.deactivate_binding(binding)

      assert Bindings.get_by_channel(:telegram, "inactive-test") == nil
    end

    test "returns nil when no binding exists" do
      assert Bindings.get_by_channel(:telegram, "nonexistent") == nil
    end
  end

  describe "Bindings.list_bindings_for_team/1" do
    test "lists all active bindings for a team" do
      team_id = "team-list-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Bindings.create_binding(%{channel: :telegram, channel_id: "list-1", team_id: team_id})

      {:ok, _} =
        Bindings.create_binding(%{channel: :discord, channel_id: "list-2", team_id: team_id})

      bindings = Bindings.list_bindings_for_team(team_id)
      assert length(bindings) == 2
    end

    test "excludes inactive bindings" do
      team_id = "team-exclude-#{System.unique_integer([:positive])}"

      {:ok, b1} =
        Bindings.create_binding(%{channel: :telegram, channel_id: "excl-1", team_id: team_id})

      {:ok, _} =
        Bindings.create_binding(%{channel: :discord, channel_id: "excl-2", team_id: team_id})

      Bindings.deactivate_binding(b1)

      bindings = Bindings.list_bindings_for_team(team_id)
      assert length(bindings) == 1
      assert hd(bindings).channel == :discord
    end

    test "returns empty list for unknown team" do
      assert Bindings.list_bindings_for_team("no-such-team") == []
    end
  end

  describe "Bindings.deactivate_binding/1" do
    test "soft-deletes a binding by setting active to false" do
      {:ok, binding} =
        Bindings.create_binding(%{
          channel: :telegram,
          channel_id: "deactivate-test",
          team_id: "team-deactivate"
        })

      assert {:ok, deactivated} = Bindings.deactivate_binding(binding)
      assert deactivated.active == false
    end
  end

  describe "Bindings.find_or_create/3" do
    test "creates a new binding when none exists" do
      assert {:ok, binding} = Bindings.find_or_create(:telegram, "foc-new", "team-foc")
      assert binding.channel == :telegram
      assert binding.channel_id == "foc-new"
      assert binding.team_id == "team-foc"
    end

    test "returns existing active binding" do
      {:ok, original} = Bindings.find_or_create(:telegram, "foc-existing", "team-foc-2")
      {:ok, found} = Bindings.find_or_create(:telegram, "foc-existing", "team-foc-2")

      assert found.id == original.id
    end
  end
end
