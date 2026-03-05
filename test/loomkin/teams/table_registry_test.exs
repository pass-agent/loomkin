defmodule Loomkin.Teams.TableRegistryTest do
  use ExUnit.Case, async: false

  alias Loomkin.Teams.TableRegistry

  describe "get_table/1" do
    test "returns {:error, :not_found} for nonexistent team" do
      assert {:error, :not_found} =
               TableRegistry.get_table("does-not-exist-#{System.unique_integer()}")
    end

    test "returns {:ok, ref} for existing team" do
      team_id = "table-reg-test-#{System.unique_integer([:positive])}"
      {:ok, ref} = TableRegistry.create_table(team_id)

      assert {:ok, ^ref} = TableRegistry.get_table(team_id)

      TableRegistry.delete_table(team_id)
    end
  end

  describe "get_table!/1" do
    test "raises ArgumentError for nonexistent team" do
      assert_raise ArgumentError, ~r/No ETS table for team/, fn ->
        TableRegistry.get_table!("does-not-exist-#{System.unique_integer()}")
      end
    end

    test "returns ref for existing team" do
      team_id = "table-reg-test-bang-#{System.unique_integer([:positive])}"
      {:ok, ref} = TableRegistry.create_table(team_id)

      assert ^ref = TableRegistry.get_table!(team_id)

      TableRegistry.delete_table(team_id)
    end
  end
end
