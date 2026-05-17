defmodule Loomkin.Orchestration.ExecutorTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Executor
  alias Loomkin.Orchestration.Schema.ReviewVerdict

  defp ok_verdict do
    %ReviewVerdict{
      verdict: :pass,
      reviewer: "stub",
      evidence: ["lib/x.ex:1"],
      blocking: [],
      warnings: [],
      rationale: "ok"
    }
  end

  test "runs work units in topological order and collects commit shas" do
    callbacks = %{
      implementer: fn wu -> {:ok, %{"wu" => wu.id}} end,
      validator: fn _ -> :ok end,
      reviewer: fn _ -> {:pass, [ok_verdict()]} end,
      committer: fn _ -> {:ok, "sha-#{System.unique_integer([:positive])}"} end
    }

    work_units = [
      %{id: "wu-2", deps: ["wu-1"]},
      %{id: "wu-1", deps: []},
      %{id: "wu-3", deps: ["wu-1", "wu-2"]}
    ]

    {:ok, results} = Executor.run(%{id: "epic-x"}, work_units, callbacks: callbacks)

    assert Map.keys(results) |> Enum.sort() == ["wu-1", "wu-2", "wu-3"]
    assert results["wu-1"].status == :done
    assert is_binary(results["wu-1"].commit_sha)
  end

  test "fails the whole run if a work unit cannot pass" do
    callbacks = %{
      implementer: fn _ -> {:ok, %{}} end,
      validator: fn _ -> {:error, ["always bad"]} end,
      reviewer: fn _ -> {:pass, [ok_verdict()]} end,
      committer: fn _ -> {:ok, "sha"} end
    }

    work_units = [%{id: "wu-1", deps: []}]

    assert {:error, {:work_unit_failed, "wu-1", _}} =
             Executor.run(%{id: "e"}, work_units, callbacks: callbacks, max_iterations: 1)
  end
end
