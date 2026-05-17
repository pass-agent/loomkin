defmodule Loomkin.Orchestration.WorkUnitPipelineTest do
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Schema.ReviewVerdict
  alias Loomkin.Orchestration.WorkUnitPipeline

  defp wait_for(server, predicate, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(server, predicate, deadline)
  end

  defp do_wait_for(server, predicate, deadline) do
    {state, _data} = WorkUnitPipeline.status(server)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for predicate; last state: #{inspect(state)}")

      true ->
        Process.sleep(5)
        do_wait_for(server, predicate, deadline)
    end
  end

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

  defp fail_verdict do
    %ReviewVerdict{
      verdict: :fail,
      reviewer: "stub",
      evidence: ["lib/x.ex:2"],
      blocking: ["nope"],
      warnings: [],
      rationale: "no"
    }
  end

  test "happy path: implement → validate → adversarial_review → commit → done" do
    callbacks = %{
      implementer: fn _wu -> {:ok, "artifact"} end,
      validator: fn _art -> :ok end,
      reviewer: fn _art -> {:pass, [ok_verdict()]} end,
      committer: fn _art -> {:ok, "sha-1"} end
    }

    {:ok, pid} =
      WorkUnitPipeline.start_link(
        work_unit: %{id: "wu-1", title: "t"},
        callbacks: callbacks,
        owner: self()
      )

    WorkUnitPipeline.start(pid)

    state = wait_for(pid, &(&1 == :done))
    assert state == :done

    assert_receive {:work_unit_pipeline, ^pid, :completed}, 1_000
  end

  test "validator failure retries implement up to the cap then fails" do
    callbacks = %{
      implementer: fn _wu -> {:ok, "artifact"} end,
      validator: fn _art -> {:error, ["bad"]} end,
      reviewer: fn _art -> {:pass, [ok_verdict()]} end,
      committer: fn _art -> {:ok, "sha-1"} end
    }

    {:ok, pid} =
      WorkUnitPipeline.start_link(
        work_unit: %{id: "wu-2", title: "t"},
        callbacks: callbacks,
        max_iterations: 2,
        owner: self()
      )

    WorkUnitPipeline.start(pid)

    state = wait_for(pid, &(&1 == :failed))
    assert state == :failed
    assert_receive {:work_unit_pipeline, ^pid, :failed}, 1_000
  end

  test "adversarial review fail triggers retry then succeeds" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    callbacks = %{
      implementer: fn _wu -> {:ok, "artifact"} end,
      validator: fn _ -> :ok end,
      reviewer: fn _ ->
        n = Agent.get_and_update(agent, &{&1, &1 + 1})
        if n == 0, do: {:fail, [fail_verdict()]}, else: {:pass, [ok_verdict()]}
      end,
      committer: fn _ -> {:ok, "sha-2"} end
    }

    {:ok, pid} =
      WorkUnitPipeline.start_link(
        work_unit: %{id: "wu-3", title: "t"},
        callbacks: callbacks,
        max_iterations: 3,
        owner: self()
      )

    WorkUnitPipeline.start(pid)

    state = wait_for(pid, &(&1 in [:done, :failed]), 2_000)
    assert state == :done
    assert_receive {:work_unit_pipeline, ^pid, :completed}, 1_000
  end
end
