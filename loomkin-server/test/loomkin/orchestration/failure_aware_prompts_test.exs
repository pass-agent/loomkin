defmodule Loomkin.Orchestration.FailureAwarePromptsTest do
  @moduledoc """
  R1 acceptance: when an attempt fails adversarial review, the next
  implementer invocation must see the failure verdicts under
  `payload.prior_failures`. The rendering helpers (`Workers.Base.render_input/1`
  and `Workers.TeamsCoder.render_prompt/2`) must surface them in a "## Prior
  attempts" markdown section so the agent can actually read them.
  """
  use ExUnit.Case, async: true

  alias Loomkin.Orchestration.Schema.ReviewVerdict
  alias Loomkin.Orchestration.Workers.{Base, TeamsCoder}
  alias Loomkin.Orchestration.WorkUnitPipeline

  defp wait_for(server, predicate, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(server, predicate, deadline)
  end

  defp do_wait_for(server, predicate, deadline) do
    {state, data} = WorkUnitPipeline.status(server)

    cond do
      predicate.(state) ->
        {state, data}

      System.monotonic_time(:millisecond) > deadline ->
        flunk("timed out waiting for predicate; last state: #{inspect(state)}")

      true ->
        Process.sleep(5)
        do_wait_for(server, predicate, deadline)
    end
  end

  defp fail_verdict do
    %ReviewVerdict{
      verdict: :fail,
      reviewer: "stub-reviewer",
      evidence: ["lib/x.ex:42"],
      blocking: ["unhandled nil case"],
      warnings: [],
      rationale: "must handle nil"
    }
  end

  defp ok_verdict do
    %ReviewVerdict{
      verdict: :pass,
      reviewer: "stub-reviewer",
      evidence: ["lib/x.ex:1"],
      blocking: [],
      warnings: [],
      rationale: "ok"
    }
  end

  describe "WorkUnitPipeline prior_failures wiring" do
    test "review fail → retry into :implement records the verdicts in prior_failures, second call sees them" do
      {:ok, agent} = Agent.start_link(fn -> %{calls: 0, implementer_payloads: []} end)

      callbacks = %{
        # arity-2 implementer — receives the bare work_unit + rich payload.
        # We snapshot each payload so the test can assert on the prior_failures
        # list as it grows.
        implementer: fn _wu, payload ->
          Agent.update(agent, fn s ->
            %{s | implementer_payloads: s.implementer_payloads ++ [payload]}
          end)

          {:ok, %{"files_touched" => ["lib/x.ex"], "notes" => "wrote stuff"}}
        end,
        validator: fn _art, _payload -> :ok end,
        reviewer: fn _art, _payload ->
          n = Agent.get_and_update(agent, fn s -> {s.calls, %{s | calls: s.calls + 1}} end)
          if n == 0, do: {:fail, [fail_verdict()]}, else: {:pass, [ok_verdict()]}
        end,
        committer: fn _art, _payload -> {:ok, "sha-x"} end
      }

      {:ok, pid} =
        WorkUnitPipeline.start_link(
          work_unit: %{id: "wu-prior", title: "do the thing"},
          callbacks: callbacks,
          max_iterations: 3,
          owner: self()
        )

      WorkUnitPipeline.start(pid)

      {state, data} = wait_for(pid, &(&1 in [:done, :failed]))
      assert state == :done

      payloads = Agent.get(agent, & &1.implementer_payloads)
      assert length(payloads) == 2, "expected implementer to run twice (initial + retry)"

      [first, second] = payloads

      assert first.prior_failures == [], "first attempt should see no prior failures"

      assert [%{iteration: 1, verdicts: [%ReviewVerdict{} = v]}] = second.prior_failures
      assert v.blocking == ["unhandled nil case"]

      # The pipeline data itself should also carry the recorded failures.
      assert [%{iteration: 1}] = data.prior_failures
    end

    test "validator failure also records prior_failures as synthetic verdicts" do
      {:ok, agent} = Agent.start_link(fn -> %{calls: 0, payloads: []} end)

      callbacks = %{
        implementer: fn _wu, payload ->
          Agent.update(agent, fn s -> %{s | payloads: s.payloads ++ [payload]} end)
          {:ok, %{"files_touched" => ["lib/x.ex"]}}
        end,
        validator: fn _art, _payload ->
          n = Agent.get_and_update(agent, fn s -> {s.calls, %{s | calls: s.calls + 1}} end)
          if n == 0, do: {:error, ["missing tests"]}, else: :ok
        end,
        reviewer: fn _art, _payload -> {:pass, [ok_verdict()]} end,
        committer: fn _art, _payload -> {:ok, "sha-y"} end
      }

      {:ok, pid} =
        WorkUnitPipeline.start_link(
          work_unit: %{id: "wu-val", title: "validate fail"},
          callbacks: callbacks,
          max_iterations: 3,
          owner: self()
        )

      WorkUnitPipeline.start(pid)
      {state, _data} = wait_for(pid, &(&1 in [:done, :failed]))
      assert state == :done

      payloads = Agent.get(agent, & &1.payloads)
      assert [first, second] = payloads
      assert first.prior_failures == []

      assert [%{iteration: 1, verdicts: [verdict]}] = second.prior_failures
      assert verdict.blocking == ["missing tests"]
      assert verdict.reviewer == "validator"
    end

    test "legacy arity-1 callbacks still receive the bare work_unit / artifact" do
      # All existing WorkUnitPipeline fixtures inject `fn _wu -> ... end`
      # closures. The tolerant dispatcher must keep them working unchanged.
      callbacks = %{
        implementer: fn wu ->
          assert is_map(wu)
          assert wu.id == "wu-legacy"
          {:ok, %{"files_touched" => ["lib/x.ex"]}}
        end,
        validator: fn art ->
          assert is_map(art)
          :ok
        end,
        reviewer: fn _art -> {:pass, [ok_verdict()]} end,
        committer: fn _art -> {:ok, "sha-legacy"} end
      }

      {:ok, pid} =
        WorkUnitPipeline.start_link(
          work_unit: %{id: "wu-legacy", title: "legacy"},
          callbacks: callbacks,
          owner: self()
        )

      WorkUnitPipeline.start(pid)
      {state, _data} = wait_for(pid, &(&1 in [:done, :failed]))
      assert state == :done
    end
  end

  describe "Workers.Base.render_input/1" do
    test "renders a prior_failures section with blocking + evidence when non-empty" do
      input = %{
        work_unit: %{title: "do something"},
        prior_failures: [
          %{
            iteration: 1,
            verdicts: [fail_verdict()]
          }
        ]
      }

      rendered = Base.render_input(input)

      assert rendered =~ "## Prior attempts (DO NOT repeat these failures)"
      assert rendered =~ "### Attempt 1"
      assert rendered =~ "stub-reviewer"
      assert rendered =~ "unhandled nil case"
      assert rendered =~ "lib/x.ex:42"
      # The work_unit map still renders alongside the section.
      assert rendered =~ "## work_unit"
    end

    test "omits the prior_failures section when empty or missing" do
      assert Base.render_input(%{work_unit: %{title: "t"}, prior_failures: []}) =~
               "## work_unit"

      refute Base.render_input(%{work_unit: %{title: "t"}}) =~ "## Prior attempts"
    end
  end

  describe "TeamsCoder.render_prompt/2" do
    test "prepends prior failures section when supplied" do
      wu = %{
        title: "do the thing",
        description: "desc",
        file_scope: ["lib/x.ex"],
        dod_items: [%{id: "d1", text: "tests pass"}]
      }

      prior = [%{iteration: 1, verdicts: [fail_verdict()]}]
      prompt = TeamsCoder.render_prompt(wu, prior)

      assert prompt =~ "## Prior attempts (DO NOT repeat these failures)"
      assert prompt =~ "### Attempt 1"
      assert prompt =~ "unhandled nil case"
      assert prompt =~ "lib/x.ex:42"
      # Existing work-unit body still present.
      assert prompt =~ "# Work unit: do the thing"
      # The prior section must appear BEFORE the work-unit header so the agent
      # reads the failure context first.
      assert :binary.match(prompt, "## Prior attempts") <
               :binary.match(prompt, "# Work unit:")
    end

    test "no prior section when failures list is empty" do
      wu = %{title: "t", description: "d", file_scope: [], dod_items: []}
      prompt = TeamsCoder.render_prompt(wu, [])
      refute prompt =~ "## Prior attempts"
      assert prompt =~ "# Work unit: t"
    end
  end
end
