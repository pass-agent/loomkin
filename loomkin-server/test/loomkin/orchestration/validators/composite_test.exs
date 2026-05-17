defmodule Loomkin.Orchestration.Validators.CompositeTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Validators.Composite
  alias Loomkin.Orchestration.Validators.Validator

  defmodule AlwaysOk do
    @behaviour Validator
    def name, do: :always_ok
    def validate(_payload, _opts \\ []), do: :ok
  end

  defmodule AlwaysFail do
    @behaviour Validator
    def name, do: :always_fail
    def validate(_payload, _opts \\ []), do: {:error, ["lib/x.ex:1: nope"]}
  end

  test "all-ok composite returns :ok" do
    assert :ok ==
             Composite.validate(%{worktree_path: "/tmp/fake"}, validators: [AlwaysOk, AlwaysOk])
  end

  test "any-fail composite returns :error with all diagnostics prefixed by validator name" do
    assert {:error, errs} =
             Composite.validate(%{worktree_path: "/tmp/fake"}, validators: [AlwaysOk, AlwaysFail])

    assert Enum.any?(errs, &String.starts_with?(&1, "[always_fail]"))
  end

  test "missing payload key produces a descriptive error from real validators" do
    assert {:error, errs} =
             Composite.validate(%{}, validators: [Loomkin.Orchestration.Validators.ElixirFormat])

    assert Enum.any?(errs, &String.contains?(&1, "missing :worktree_path"))
  end
end
