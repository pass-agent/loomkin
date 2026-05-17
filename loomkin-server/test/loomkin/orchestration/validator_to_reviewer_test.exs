defmodule Loomkin.Orchestration.ValidatorToReviewerTest do
  @moduledoc """
  End-to-end-ish coverage of the validator → adversarial-reviewer diagnostic
  bridge:

    * `Validators.Composite` aggregates warnings from `{:ok, [...]}` children.
    * `WorkUnitPipeline` stashes warnings on `data.validator_diagnostics` and
      forwards them in the reviewer payload.
    * `AdversarialReviewGate` accepts `:validator_diagnostics` and threads
      them into the reviewer's rendered prompt (the LLM stub captures the
      messages so we can assert the diagnostic string is present).
  """
  use ExUnit.Case, async: false

  alias Loomkin.Orchestration.Gates.AdversarialReviewGate
  alias Loomkin.Orchestration.LLM.Stub
  alias Loomkin.Orchestration.Validators.Composite
  alias Loomkin.Orchestration.Validators.Validator
  alias Loomkin.Orchestration.WorkUnitPipeline

  defmodule WarnValidator do
    @behaviour Validator
    def name, do: :warn_validator
    def validate(_payload, _opts \\ []), do: {:ok, ["lib/x.ex:5: undef foo"]}
  end

  defmodule OkValidator do
    @behaviour Validator
    def name, do: :ok_validator
    def validate(_payload, _opts \\ []), do: :ok
  end

  defmodule FailValidator do
    @behaviour Validator
    def name, do: :fail_validator
    def validate(_payload, _opts \\ []), do: {:error, ["lib/y.ex:1: boom"]}
  end

  # ──────────────────────────────────────────────────────────────────────────
  describe "Composite aggregation" do
    test "collects warnings from {:ok, [...]} children into a single {:ok, _}" do
      assert {:ok, warnings} =
               Composite.validate(%{worktree_path: "/tmp/fake"},
                 validators: [OkValidator, WarnValidator]
               )

      assert Enum.any?(warnings, &String.contains?(&1, "[warn_validator]"))
      assert Enum.any?(warnings, &String.contains?(&1, "lib/x.ex:5: undef foo"))
    end

    test "warnings are NOT merged into the error list when a sibling fails" do
      assert {:error, errs} =
               Composite.validate(%{worktree_path: "/tmp/fake"},
                 validators: [WarnValidator, FailValidator]
               )

      # Errors are only the failing validator's diagnostics, prefixed.
      assert Enum.any?(errs, &String.starts_with?(&1, "[fail_validator]"))
      refute Enum.any?(errs, &String.contains?(&1, "warn_validator"))
    end

    test "all-ok composite still returns plain :ok" do
      assert :ok ==
               Composite.validate(%{worktree_path: "/tmp/fake"},
                 validators: [OkValidator, OkValidator]
               )
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  describe "WorkUnitPipeline threads diagnostics into the reviewer payload" do
    test "{:ok, warnings} from validator lands on data.validator_diagnostics and in the reviewer payload" do
      test_pid = self()
      warnings = ["lib/x.ex:5: undef foo"]

      callbacks = %{
        implementer: fn _wu -> {:ok, %{files_touched: ["lib/x.ex"]}} end,
        validator: fn _art -> {:ok, warnings} end,
        reviewer: fn _art, payload ->
          send(test_pid, {:reviewer_payload, payload})

          {:pass,
           [
             %Loomkin.Orchestration.Schema.ReviewVerdict{
               verdict: :pass,
               reviewer: "dod_verifier",
               evidence: ["lib/x.ex:5"],
               blocking: [],
               warnings: [],
               rationale: "ok"
             }
           ]}
        end,
        committer: fn _art -> {:ok, "sha-test"} end
      }

      {:ok, pid} =
        WorkUnitPipeline.start_link(
          work_unit: %{id: "wu-validator-test", title: "t"},
          callbacks: callbacks,
          owner: self()
        )

      WorkUnitPipeline.start(pid)

      assert_receive {:work_unit_pipeline, ^pid, :completed}, 2_000
      assert_receive {:reviewer_payload, payload}, 2_000

      assert payload.validator_diagnostics == warnings
    end

    test ":ok validator result clears validator_diagnostics (empty list in payload)" do
      test_pid = self()

      callbacks = %{
        implementer: fn _wu -> {:ok, %{files_touched: ["lib/x.ex"]}} end,
        validator: fn _art -> :ok end,
        reviewer: fn _art, payload ->
          send(test_pid, {:reviewer_payload, payload})

          {:pass,
           [
             %Loomkin.Orchestration.Schema.ReviewVerdict{
               verdict: :pass,
               reviewer: "dod_verifier",
               evidence: ["lib/x.ex:1"],
               blocking: [],
               warnings: [],
               rationale: "ok"
             }
           ]}
        end,
        committer: fn _art -> {:ok, "sha-test"} end
      }

      {:ok, pid} =
        WorkUnitPipeline.start_link(
          work_unit: %{id: "wu-ok-test", title: "t"},
          callbacks: callbacks,
          owner: self()
        )

      WorkUnitPipeline.start(pid)

      assert_receive {:work_unit_pipeline, ^pid, :completed}, 2_000
      assert_receive {:reviewer_payload, payload}, 2_000

      assert payload.validator_diagnostics == []
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  describe "AdversarialReviewGate forwards diagnostics into the rendered LLM prompt" do
    setup do
      sup = String.to_atom("AdvDiagSup.#{System.unique_integer([:positive])}")
      start_supervised!({Task.Supervisor, name: sup})
      start_supervised!(Stub)

      prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])

      Application.put_env(
        :loomkin,
        Loomkin.Orchestration,
        Keyword.put(prev, :llm_adapter, RecordingStub)
      )

      on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, prev) end)

      %{sup: sup}
    end

    test "validator_diagnostics show up in the messages the reviewer LLM sees", %{sup: sup} do
      RecordingStub.start_link()

      RecordingStub.queue(
        ~s({"verdict":"pass","evidence":["lib/x.ex:5"],"blocking":[],"warnings":[],"rationale":"ok"})
      )

      diag = "[warn_validator] lib/x.ex:5: undef foo"

      {_agg, _verdicts} =
        AdversarialReviewGate.run(
          %{
            epic_id: "e1",
            artifact: "diff...",
            validator_diagnostics: [diag]
          },
          task_supervisor: sup
        )

      messages = RecordingStub.last_messages()
      user_msg = Enum.find(messages, &(&1.role == :user)).content

      assert user_msg =~ "## validator_diagnostics"
      assert user_msg =~ diag
    end

    test "empty validator_diagnostics list is omitted from the rendered prompt", %{sup: sup} do
      RecordingStub.start_link()

      RecordingStub.queue(
        ~s({"verdict":"pass","evidence":["lib/x.ex:5"],"blocking":[],"warnings":[],"rationale":"ok"})
      )

      {_agg, _verdicts} =
        AdversarialReviewGate.run(
          %{
            epic_id: "e1",
            artifact: "diff...",
            validator_diagnostics: []
          },
          task_supervisor: sup
        )

      messages = RecordingStub.last_messages()
      user_msg = Enum.find(messages, &(&1.role == :user)).content

      refute user_msg =~ "validator_diagnostics"
    end
  end
end

defmodule RecordingStub do
  @moduledoc """
  Tiny LLM adapter that records the last set of messages it received, then
  pops a scripted response off a queue. Used by the reviewer-prompt test so
  we can assert that `validator_diagnostics` makes it into the prompt body.
  """
  @behaviour Loomkin.Orchestration.LLM

  use Agent

  @name __MODULE__

  def start_link(_ \\ []) do
    case Agent.start_link(fn -> %{queue: [], last_messages: nil} end, name: @name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def queue(text) when is_binary(text) do
    Agent.update(@name, fn s -> %{s | queue: s.queue ++ [text]} end)
  end

  def last_messages, do: Agent.get(@name, & &1.last_messages)

  @impl true
  def complete(messages, _opts) do
    Agent.get_and_update(@name, fn s ->
      case s.queue do
        [text | rest] -> {{:ok, text}, %{s | queue: rest, last_messages: messages}}
        [] -> {{:error, :no_recording_stub_response}, %{s | last_messages: messages}}
      end
    end)
  end
end
