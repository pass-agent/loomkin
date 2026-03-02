defmodule Loomkin.Telemetry.MetricsTest do
  use ExUnit.Case

  alias Loomkin.Telemetry.Metrics

  # These tests rely on the application-started Metrics GenServer
  # which creates and owns the ETS table

  describe "session_metrics/1" do
    test "returns default metrics for unknown session" do
      metrics = Metrics.session_metrics("nonexistent-session")
      assert metrics.prompt_tokens == 0
      assert metrics.completion_tokens == 0
      assert metrics.cost_usd == 0
      assert metrics.llm_requests == 0
      assert metrics.tool_calls == 0
    end
  end

  describe "global_metrics/0" do
    test "returns global metrics" do
      global = Metrics.global_metrics()
      assert is_map(global)
      assert Map.has_key?(global, :total_tokens)
      assert Map.has_key?(global, :total_cost)
      assert Map.has_key?(global, :total_requests)
    end
  end

  describe "model_breakdown/0" do
    test "returns a map" do
      breakdown = Metrics.model_breakdown()
      assert is_map(breakdown)
    end
  end

  describe "tool_stats/0" do
    test "returns a map" do
      stats = Metrics.tool_stats()
      assert is_map(stats)
    end
  end

  describe "telemetry event handling" do
    test "LLM stop event updates session and global metrics" do
      session_id = "metrics-test-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:loomkin, :llm, :request, :stop],
        %{duration: System.convert_time_unit(100, :millisecond, :native)},
        %{
          session_id: session_id,
          model: "anthropic:test-model",
          input_tokens: 100,
          output_tokens: 50,
          total_cost: 0.005
        }
      )

      # Allow async processing
      Process.sleep(10)

      metrics = Metrics.session_metrics(session_id)
      assert metrics.prompt_tokens == 100
      assert metrics.completion_tokens == 50
      assert metrics.cost_usd == 0.005
      assert metrics.llm_requests == 1

      # Verify model breakdown updated
      breakdown = Metrics.model_breakdown()
      assert Map.has_key?(breakdown, "anthropic:test-model")
    end

    test "tool stop event updates session and tool stats" do
      session_id = "tool-test-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:loomkin, :tool, :execute, :stop],
        %{duration: System.convert_time_unit(50, :millisecond, :native)},
        %{
          session_id: session_id,
          tool_name: "file_read",
          success: true
        }
      )

      Process.sleep(10)

      metrics = Metrics.session_metrics(session_id)
      assert metrics.tool_calls == 1

      stats = Metrics.tool_stats()
      assert stats["file_read"].count == 1 || stats["file_read"].count > 0
      assert stats["file_read"].successes >= 1
    end

    test "session message event updates message counts" do
      session_id = "msg-test-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:loomkin, :session, :message],
        %{system_time: System.system_time()},
        %{session_id: session_id, role: :user}
      )

      :telemetry.execute(
        [:loomkin, :session, :message],
        %{system_time: System.system_time()},
        %{session_id: session_id, role: :assistant}
      )

      Process.sleep(10)

      metrics = Metrics.session_metrics(session_id)
      assert metrics.messages.user == 1
      assert metrics.messages.assistant == 1
    end

    test "accumulates across multiple events" do
      session_id = "accum-test-#{System.unique_integer([:positive])}"

      for _ <- 1..3 do
        :telemetry.execute(
          [:loomkin, :llm, :request, :stop],
          %{duration: System.convert_time_unit(10, :millisecond, :native)},
          %{
            session_id: session_id,
            model: "test:model",
            input_tokens: 10,
            output_tokens: 5,
            total_cost: 0.001
          }
        )
      end

      Process.sleep(10)

      metrics = Metrics.session_metrics(session_id)
      assert metrics.prompt_tokens == 30
      assert metrics.completion_tokens == 15
      assert metrics.llm_requests == 3
    end
  end

  describe "all_sessions/0" do
    test "returns list of session summaries" do
      session_id = "list-test-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:loomkin, :llm, :request, :stop],
        %{duration: 0},
        %{session_id: session_id, model: "test", input_tokens: 1, output_tokens: 1, total_cost: 0}
      )

      Process.sleep(10)

      sessions = Metrics.all_sessions()
      assert is_list(sessions)

      found = Enum.find(sessions, &(&1.session_id == session_id))
      assert found != nil
      assert found.prompt_tokens == 1
    end
  end
end
