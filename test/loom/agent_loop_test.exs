defmodule Loom.AgentLoopTest do
  use ExUnit.Case, async: true

  alias Loom.AgentLoop

  describe "format_tool_result/1" do
    test "extracts text from {:ok, %{result: text}}" do
      assert AgentLoop.format_tool_result({:ok, %{result: "hello"}}) == "hello"
    end

    test "extracts binary from {:ok, text}" do
      assert AgentLoop.format_tool_result({:ok, "direct"}) == "direct"
    end

    test "inspects map from {:ok, map}" do
      result = AgentLoop.format_tool_result({:ok, %{a: 1}})
      assert result =~ "a:"
    end

    test "formats error with message key" do
      assert AgentLoop.format_tool_result({:error, %{message: "boom"}}) == "Error: boom"
    end

    test "formats binary error" do
      assert AgentLoop.format_tool_result({:error, "failed"}) == "Error: failed"
    end

    test "inspects other errors" do
      result = AgentLoop.format_tool_result({:error, :timeout})
      assert result == "Error: :timeout"
    end
  end

  describe "run/2 option validation" do
    test "raises when :model is missing" do
      assert_raise KeyError, ~r/key :model not found/, fn ->
        AgentLoop.run([], system_prompt: "test", tools: [])
      end
    end

    test "raises when :system_prompt is missing" do
      assert_raise KeyError, ~r/key :system_prompt not found/, fn ->
        AgentLoop.run([], model: "test:model", tools: [])
      end
    end
  end

  describe "run/2 with max_iterations" do
    test "respects max_iterations of 0" do
      # max_iterations=0 means the loop exits immediately
      result =
        AgentLoop.run([], model: "test:model", system_prompt: "test", max_iterations: 0)

      assert {:error, msg, []} = result
      assert msg =~ "Maximum tool call iterations (0) exceeded"
    end
  end

  describe "run/2 with LLM error (no API key)" do
    test "returns error when LLM call fails" do
      messages = [%{role: :user, content: "Hello"}]

      result =
        AgentLoop.run(messages,
          model: "anthropic:claude-sonnet-4-6",
          system_prompt: "You are a test assistant.",
          tools: []
        )

      # LLM call will fail without API key — should return error with messages intact
      assert {:error, _reason, returned_messages} = result
      assert length(returned_messages) == 1
      assert hd(returned_messages).role == :user
    end

    test "invokes on_event callback even on error path" do
      test_pid = self()

      messages = [%{role: :user, content: "Hello"}]

      AgentLoop.run(messages,
        model: "anthropic:claude-sonnet-4-6",
        system_prompt: "You are a test assistant.",
        tools: [],
        on_event: fn event_name, payload ->
          send(test_pid, {:event, event_name, payload})
          :ok
        end
      )

      # The on_event callback should NOT be called for the error path
      # (no :new_message because the LLM call itself failed before producing a message)
      refute_received {:event, :new_message, _}
    end
  end

  describe "run/2 callbacks" do
    test "on_event receives events with default no-op" do
      # The default on_event should not crash
      result =
        AgentLoop.run([%{role: :user, content: "test"}],
          model: "test:nonexistent",
          system_prompt: "test",
          tools: []
        )

      assert {:error, _reason, _messages} = result
    end
  end

  describe "run/2 with check_permission callback" do
    test "check_permission callback is only invoked when tools are present" do
      # Without tools, LLM won't produce tool calls, so check_permission won't fire.
      # This is a structural test — the callback wiring is correct.
      test_pid = self()

      AgentLoop.run([%{role: :user, content: "test"}],
        model: "test:nonexistent",
        system_prompt: "test",
        tools: [],
        check_permission: fn tool_name, tool_path ->
          send(test_pid, {:permission_check, tool_name, tool_path})
          :allowed
        end
      )

      refute_received {:permission_check, _, _}
    end
  end

  describe "default_run_tool/3" do
    @tag :tmp_dir
    test "atomizes string-keyed args and runs the tool successfully", %{tmp_dir: tmp_dir} do
      # Write a file the tool can read
      file_path = Path.join(tmp_dir, "hello.txt")
      File.write!(file_path, "line one\nline two\n")

      # Simulate how the LLM delivers args: string keys
      string_keyed_args = %{"file_path" => "hello.txt"}
      context = %{project_path: tmp_dir, session_id: nil}

      result = AgentLoop.default_run_tool(Loom.Tools.FileRead, string_keyed_args, context)

      assert is_binary(result)
      assert result =~ "line one"
      assert result =~ "line two"
    end

    @tag :tmp_dir
    test "returns formatted error string when tool returns an error", %{tmp_dir: tmp_dir} do
      string_keyed_args = %{"file_path" => "does_not_exist.txt"}
      context = %{project_path: tmp_dir, session_id: nil}

      result = AgentLoop.default_run_tool(Loom.Tools.FileRead, string_keyed_args, context)

      assert is_binary(result)
      assert result =~ "Error:"
      assert result =~ "does_not_exist.txt"
    end

    @tag :tmp_dir
    test "atomizes optional integer args (offset, limit)", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "paged.txt")
      File.write!(file_path, Enum.map_join(1..10, "\n", &"line #{&1}"))

      string_keyed_args = %{"file_path" => "paged.txt", "offset" => 3, "limit" => 2}
      context = %{project_path: tmp_dir, session_id: nil}

      result = AgentLoop.default_run_tool(Loom.Tools.FileRead, string_keyed_args, context)

      assert is_binary(result)
      assert result =~ "line 3"
      assert result =~ "line 4"
      refute result =~ "line 1"
      refute result =~ "line 5"
    end

    @tag :tmp_dir
    test "does not crash when tool module raises an exception", %{tmp_dir: tmp_dir} do
      string_keyed_args = %{"file_path" => "../../etc/passwd"}
      context = %{project_path: tmp_dir, session_id: nil}

      result = AgentLoop.default_run_tool(Loom.Tools.FileRead, string_keyed_args, context)

      assert is_binary(result)
      assert result =~ "Error:"
    end
  end

  describe "resume/3" do
    test "resume with invalid pending_info raises on missing keys" do
      # Resume expects a specific pending_info structure
      assert_raise KeyError, fn ->
        AgentLoop.resume("result", %{}, [])
      end
    end
  end
end
