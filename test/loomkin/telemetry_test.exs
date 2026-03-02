defmodule Loomkin.TelemetryTest do
  use ExUnit.Case, async: true

  alias Loomkin.Telemetry, as: LoomkinTelemetry

  setup do
    # Attach test handlers to capture events
    test_pid = self()

    events = [
      [:loomkin, :llm, :request, :start],
      [:loomkin, :llm, :request, :stop],
      [:loomkin, :tool, :execute, :start],
      [:loomkin, :tool, :execute, :stop],
      [:loomkin, :session, :message],
      [:loomkin, :decision, :logged]
    ]

    handler_id = "test-handler-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "span_llm_request/2" do
    test "emits start and stop events on success" do
      metadata = %{session_id: "test-session", model: "anthropic:test"}

      result =
        LoomkinTelemetry.span_llm_request(metadata, fn ->
          {:ok, %{}}
        end)

      assert result == {:ok, %{}}

      assert_received {:telemetry_event, [:loomkin, :llm, :request, :start], %{system_time: _},
                        %{session_id: "test-session", model: "anthropic:test"}}

      assert_received {:telemetry_event, [:loomkin, :llm, :request, :stop], %{duration: duration},
                        stop_meta}

      assert is_integer(duration)
      assert stop_meta.session_id == "test-session"
    end

    test "emits error metadata on failure" do
      metadata = %{session_id: "test-session", model: "anthropic:test"}

      result =
        LoomkinTelemetry.span_llm_request(metadata, fn ->
          {:error, :timeout}
        end)

      assert result == {:error, :timeout}

      assert_received {:telemetry_event, [:loomkin, :llm, :request, :stop], %{duration: _},
                        %{error: true}}
    end
  end

  describe "span_tool_execute/2" do
    test "emits start and stop events with success flag" do
      metadata = %{tool_name: "file_read", session_id: "test-session"}

      result =
        LoomkinTelemetry.span_tool_execute(metadata, fn ->
          {:ok, "file contents"}
        end)

      assert result == {:ok, "file contents"}

      assert_received {:telemetry_event, [:loomkin, :tool, :execute, :start], %{system_time: _},
                        %{tool_name: "file_read"}}

      assert_received {:telemetry_event, [:loomkin, :tool, :execute, :stop], %{duration: _},
                        %{success: true, tool_name: "file_read"}}
    end

    test "marks success as false on error" do
      metadata = %{tool_name: "shell", session_id: "test-session"}

      LoomkinTelemetry.span_tool_execute(metadata, fn ->
        {:error, "command failed"}
      end)

      assert_received {:telemetry_event, [:loomkin, :tool, :execute, :stop], _,
                        %{success: false, tool_name: "shell"}}
    end

    test "marks string results as successful" do
      metadata = %{tool_name: "file_read", session_id: "test-session"}

      LoomkinTelemetry.span_tool_execute(metadata, fn ->
        "file contents as string"
      end)

      assert_received {:telemetry_event, [:loomkin, :tool, :execute, :stop], _,
                        %{success: true}}
    end
  end

  describe "emit_session_message/1" do
    test "emits a session message event" do
      LoomkinTelemetry.emit_session_message(%{
        session_id: "test-session",
        role: :user,
        token_count: 42
      })

      assert_received {:telemetry_event, [:loomkin, :session, :message], %{system_time: _},
                        %{session_id: "test-session", role: :user, token_count: 42}}
    end
  end

  describe "emit_decision_logged/1" do
    test "emits a decision logged event" do
      LoomkinTelemetry.emit_decision_logged(%{
        session_id: "test-session",
        node_type: :decision,
        confidence: 85
      })

      assert_received {:telemetry_event, [:loomkin, :decision, :logged], %{system_time: _},
                        %{node_type: :decision, confidence: 85}}
    end
  end
end
