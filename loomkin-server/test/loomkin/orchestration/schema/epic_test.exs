defmodule Loomkin.Orchestration.Schema.EpicTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Schema.Epic

  test "valid changeset with required fields" do
    cs =
      Epic.changeset(%Epic{}, %{
        id: Ecto.UUID.generate(),
        title: "test epic",
        spec: "do the thing"
      })

    assert cs.valid?
  end

  test "rejects missing title" do
    cs = Epic.changeset(%Epic{}, %{id: Ecto.UUID.generate(), spec: "x"})
    refute cs.valid?
  end

  test "rejects priority out of 0..4" do
    cs =
      Epic.changeset(%Epic{}, %{
        id: Ecto.UUID.generate(),
        title: "t",
        spec: "s",
        priority: 9
      })

    refute cs.valid?
  end

  test "accepts DoD items via embed" do
    cs =
      Epic.changeset(%Epic{}, %{
        id: Ecto.UUID.generate(),
        title: "t",
        spec: "s",
        dod_items: [
          %{id: "1", text: "ships", verifier: :test, file_scope: ["lib/x.ex"]}
        ]
      })

    assert cs.valid?
    assert [%{text: "ships"}] = Ecto.Changeset.get_field(cs, :dod_items)
  end
end
