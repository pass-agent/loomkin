defmodule Loomkin.Signals.Extensions.CausalityTest do
  use ExUnit.Case, async: true

  alias Loomkin.Signals.Extensions.Causality

  describe "attach/2" do
    test "attaches causality metadata to a signal" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :working
        })

      result =
        Causality.attach(signal,
          team_id: "team-1",
          agent_name: "coder"
        )

      assert result.extensions["loomkin"][:team_id] == "team-1"
      assert result.extensions["loomkin"][:agent_name] == "coder"
    end

    test "includes trigger_signal_id when provided" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :idle
        })

      parent_signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "lead",
          team_id: "team-1",
          status: :working
        })

      result =
        Causality.attach(signal,
          team_id: "team-1",
          agent_name: "coder",
          trigger_signal_id: parent_signal.id
        )

      assert result.extensions["loomkin"][:trigger_signal_id] == parent_signal.id
    end

    test "includes task_id when provided" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :working
        })

      result =
        Causality.attach(signal,
          team_id: "team-1",
          agent_name: "coder",
          task_id: "task-42"
        )

      assert result.extensions["loomkin"][:task_id] == "task-42"
    end

    test "omits nil fields" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :idle
        })

      result = Causality.attach(signal, team_id: "team-1")

      causality = result.extensions["loomkin"]
      assert causality[:team_id] == "team-1"
      refute Map.has_key?(causality, "agent_name")
      refute Map.has_key?(causality, "trigger_signal_id")
      refute Map.has_key?(causality, "task_id")
    end

    test "preserves existing extensions" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :idle
        })

      signal = %{signal | extensions: %{"other" => %{"key" => "value"}}}

      result = Causality.attach(signal, team_id: "team-1")

      assert result.extensions["other"] == %{"key" => "value"}
      assert result.extensions["loomkin"][:team_id] == "team-1"
    end

    test "defaults to empty opts" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :idle
        })

      result = Causality.attach(signal)
      assert result.extensions["loomkin"] == %{}
    end
  end

  describe "extract/1" do
    test "extracts causality metadata from signal" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :idle
        })

      signal =
        Causality.attach(signal,
          team_id: "team-1",
          agent_name: "coder",
          task_id: "task-1"
        )

      extracted = Causality.extract(signal)
      assert extracted[:team_id] == "team-1"
      assert extracted[:agent_name] == "coder"
      assert extracted[:task_id] == "task-1"
    end

    test "returns empty map when no causality present" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :idle
        })

      assert Causality.extract(signal) == %{}
    end
  end

  describe "trigger_id/1" do
    test "returns trigger signal id when present" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :idle
        })

      signal = Causality.attach(signal, trigger_signal_id: "sig-parent-123")
      assert Causality.trigger_id(signal) == "sig-parent-123"
    end

    test "returns nil when no trigger present" do
      signal =
        Loomkin.Signals.Agent.Status.new!(%{
          agent_name: "coder",
          team_id: "team-1",
          status: :idle
        })

      assert Causality.trigger_id(signal) == nil
    end
  end

  describe "validate_data/1" do
    test "validates valid causality data" do
      assert {:ok, _} =
               Causality.validate_data(%{
                 team_id: "team-1",
                 agent_name: "coder"
               })
    end

    test "validates with all fields" do
      assert {:ok, _} =
               Causality.validate_data(%{
                 team_id: "team-1",
                 agent_name: "coder",
                 trigger_signal_id: "sig-123",
                 task_id: "task-1"
               })
    end

    test "validates empty data (all fields optional)" do
      assert {:ok, _} = Causality.validate_data(%{})
    end
  end
end
