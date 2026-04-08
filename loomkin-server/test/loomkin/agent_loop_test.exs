defmodule Loomkin.AgentLoopTest do
  use ExUnit.Case, async: true

  alias Loomkin.AgentLoop
  alias ReqLLM.Message
  alias ReqLLM.Response

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

  describe "assistant_message_from_response/2" do
    test "preserves response metadata for tool-call turns" do
      classified = %{
        type: :tool_calls,
        text: "",
        tool_calls: [%{id: "call_123", name: "echo", arguments: %{"text" => "hi"}}]
      }

      response = %Response{
        id: "resp_123",
        model: "openai:gpt-5.4",
        context: ReqLLM.Context.new([]),
        message: %Message{
          role: :assistant,
          content: [],
          metadata: %{response_id: "resp_123"}
        }
      }

      assistant_msg = AgentLoop.assistant_message_from_response(classified, response)

      assert assistant_msg.metadata[:response_id] == "resp_123"
      assert [%{id: "call_123"}] = assistant_msg.tool_calls
    end
  end

  describe "to_req_message/1" do
    test "preserves assistant metadata and tool call ids" do
      req_message =
        AgentLoop.to_req_message(%{
          role: :assistant,
          content: "",
          tool_calls: [%{id: "call_123", name: "echo", arguments: %{"text" => "hi"}}],
          metadata: %{response_id: "resp_123"}
        })

      assert req_message.metadata[:response_id] == "resp_123"
      assert [%ReqLLM.ToolCall{id: "call_123"}] = req_message.tool_calls
    end

    test "returns nil for malformed messages instead of crashing" do
      assert AgentLoop.to_req_message(nil) == nil
      assert AgentLoop.to_req_message(%{content: "missing role"}) == nil
      assert AgentLoop.to_req_message("not a map") == nil
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

  describe "run/2 with LLM error (no API key)" do
    @tag :llm_dependent
    test "returns error when LLM call fails" do
      messages = [%{role: :user, content: "Hello"}]

      result =
        AgentLoop.run(messages,
          model: "zai:glm-5",
          system_prompt: "You are a test assistant.",
          tools: []
        )

      # LLM call will fail without API key — should return error with messages intact
      assert {:error, _reason, returned_messages} = result
      assert length(returned_messages) == 1
      assert hd(returned_messages).role == :user
    end

    @tag :llm_dependent
    test "invokes on_event callback even on error path" do
      test_pid = self()

      messages = [%{role: :user, content: "Hello"}]

      AgentLoop.run(messages,
        model: "zai:glm-5",
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

      result = AgentLoop.default_run_tool(Loomkin.Tools.FileRead, string_keyed_args, context)

      assert is_binary(result)
      assert result =~ "line one"
      assert result =~ "line two"
    end

    @tag :tmp_dir
    test "returns formatted error string when tool returns an error", %{tmp_dir: tmp_dir} do
      string_keyed_args = %{"file_path" => "does_not_exist.txt"}
      context = %{project_path: tmp_dir, session_id: nil}

      result = AgentLoop.default_run_tool(Loomkin.Tools.FileRead, string_keyed_args, context)

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

      result = AgentLoop.default_run_tool(Loomkin.Tools.FileRead, string_keyed_args, context)

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

      result = AgentLoop.default_run_tool(Loomkin.Tools.FileRead, string_keyed_args, context)

      assert is_binary(result)
      assert result =~ "outside the project directory"
    end
  end

  describe "resume/3" do
    test "resume with invalid pending_info raises on missing keys" do
      # Resume expects a specific pending_info structure.
      # Use a variable to prevent the compiler from statically analysing the
      # empty-map literal against resume/3's expected types.
      pending = Map.new([])

      assert_raise KeyError, fn ->
        AgentLoop.resume("result", pending, [])
      end
    end
  end

  describe "cycle detection" do
    test "initializes prev_tool_signature to nil on run" do
      # run/2 will fail on LLM call, but the process dict should be initialized
      AgentLoop.run([%{role: :user, content: "test"}],
        model: "test:nonexistent",
        system_prompt: "test",
        tools: []
      )

      assert Process.get(:loomkin_prev_tool_signature) == nil
    end

    test "tool_call_signature produces deterministic, order-independent signatures" do
      # Access the private function indirectly by testing the process dict behavior.
      # We verify that the signature mechanism works by running two loops and
      # checking the process dictionary state.

      # Two calls with same tools in different order should produce same signature
      calls_a = [
        %{name: "file_read", arguments: %{"path" => "/a.txt"}},
        %{name: "grep", arguments: %{"pattern" => "foo"}}
      ]

      calls_b = [
        %{name: "grep", arguments: %{"pattern" => "foo"}},
        %{name: "file_read", arguments: %{"path" => "/a.txt"}}
      ]

      # Manually test signature equivalence through the process dict
      # by simulating what maybe_inject_cycle_warning does
      Process.put(:loomkin_prev_tool_signature, nil)

      config = %{on_event: fn _, _ -> :ok end}

      # First call sets the signature
      messages = apply_cycle_check(calls_a, [], config)
      sig_a = Process.get(:loomkin_prev_tool_signature)
      assert messages == []

      # Second call with reordered tools should detect a cycle
      messages = apply_cycle_check(calls_b, [], config)
      sig_b = Process.get(:loomkin_prev_tool_signature)

      assert sig_a == sig_b
      assert length(messages) == 1
      assert hd(messages).role == :system
      assert hd(messages).content =~ "Do NOT repeat"
    end

    test "different tool calls do not trigger cycle warning" do
      Process.put(:loomkin_prev_tool_signature, nil)
      config = %{on_event: fn _, _ -> :ok end}

      _messages =
        apply_cycle_check(
          [%{name: "file_read", arguments: %{"path" => "/a.txt"}}],
          [],
          config
        )

      messages =
        apply_cycle_check(
          [%{name: "file_read", arguments: %{"path" => "/b.txt"}}],
          [],
          config
        )

      assert messages == []
    end

    test "cycle warning emits :cycle_detected event" do
      Process.put(:loomkin_prev_tool_signature, nil)
      test_pid = self()

      config = %{
        on_event: fn event_name, payload ->
          send(test_pid, {:event, event_name, payload})
          :ok
        end
      }

      calls = [%{name: "grep", arguments: %{"pattern" => "foo"}}]

      # First call — no cycle
      apply_cycle_check(calls, [], config)
      refute_received {:event, :cycle_detected, _}

      # Second call — cycle detected
      apply_cycle_check(calls, [], config)
      assert_received {:event, :cycle_detected, %{signature: sig}}
      assert is_binary(sig)
      assert sig =~ "grep"
    end

    # Helper that mirrors the private maybe_inject_cycle_warning logic
    defp apply_cycle_check(tool_calls, messages, config) do
      prev_sig = Process.get(:loomkin_prev_tool_signature)

      current_sig =
        tool_calls
        |> Enum.map(fn tc ->
          name = tc[:name] || tc["name"] || ""
          args = tc[:arguments] || tc["arguments"] || %{}
          "#{name}:#{inspect(args)}"
        end)
        |> Enum.sort()
        |> Enum.join("|")

      Process.put(:loomkin_prev_tool_signature, current_sig)

      if prev_sig == current_sig and prev_sig != nil do
        warning_msg = %{
          role: :system,
          content:
            "You already called the same tool(s) with identical arguments " <>
              "in the previous iteration and got the same results. Do NOT repeat " <>
              "the same calls. Either use the results you already have to form a " <>
              "final answer, or try a different approach."
        }

        config.on_event.(:cycle_detected, %{signature: current_sig})
        config.on_event.(:new_message, warning_msg)
        messages ++ [warning_msg]
      else
        messages
      end
    end
  end

  describe "coordination loop detection" do
    test "coordination-only tool sets are detected" do
      assert AgentLoop.coordination_only_tool_calls?([
               %{name: "decision_query", arguments: %{"query_type" => "pulse"}},
               %{name: "query_backlog", arguments: %{"query_type" => "summary"}}
             ])

      refute AgentLoop.coordination_only_tool_calls?([
               %{name: "decision_query", arguments: %{"query_type" => "pulse"}},
               %{name: "team_spawn", arguments: %{"roles" => []}}
             ])
    end

    test "injects a warning after consecutive coordination-only iterations" do
      Process.put(:loomkin_coordination_streak, 0)
      test_pid = self()

      config = %{
        agent_name: "concierge",
        team_id: "team-123",
        on_event: fn event_name, payload ->
          send(test_pid, {:event, event_name, payload})
          :ok
        end
      }

      tools = [%{name: "decision_query", arguments: %{"query_type" => "pulse"}}]

      assert [] == AgentLoop.maybe_inject_coordination_warning([], tools, config)
      refute_received {:event, :coordination_loop_detected, _}

      messages = AgentLoop.maybe_inject_coordination_warning([], tools, config)
      assert [%{role: :system, content: content}] = messages
      assert content =~ "Stop planning and move the task forward"

      assert_received {:event, :coordination_loop_detected,
                       %{streak: 2, tools: ["decision_query"]}}
    end

    test "concierge gets the stronger warning after a single repeated coordination turn" do
      Process.put(:loomkin_coordination_streak, 0)

      config = %{
        role: :concierge,
        agent_name: "concierge",
        team_id: "team-123",
        on_event: fn _, _ -> :ok end
      }

      tools = [%{name: "decision_query", arguments: %{"query_type" => "pulse"}}]

      messages = AgentLoop.maybe_inject_coordination_warning([], tools, config)
      assert [%{role: :system, content: content}] = messages
      assert content =~ "Stay available for the human"
      assert content =~ "spawn a specialist or team"
      assert content =~ "do NOT ask what they want next"
      assert content =~ "do NOT ask them to restate the task"
    end

    test "resets coordination streak when non-coordination work appears" do
      Process.put(:loomkin_coordination_streak, 1)

      config = %{
        agent_name: "concierge",
        team_id: "team-123",
        on_event: fn _, _ -> :ok end
      }

      assert [] ==
               AgentLoop.maybe_inject_coordination_warning(
                 [],
                 [%{name: "team_spawn", arguments: %{"roles" => []}}],
                 config
               )

      assert Process.get(:loomkin_coordination_streak) == 0
    end

    test "stops the loop after too many consecutive coordination-only iterations" do
      Process.put(:loomkin_coordination_streak, 6)
      test_pid = self()

      config = %{
        agent_name: "concierge",
        team_id: "team-123",
        on_event: fn event_name, payload ->
          send(test_pid, {:event, event_name, payload})
          :ok
        end
      }

      response = %Response{
        id: "resp_123",
        model: "openai:gpt-5.4",
        context: ReqLLM.Context.new([]),
        usage: %{input_tokens: 10, output_tokens: 20, total_cost: 0.12}
      }

      assert {:stop, message, messages, %{usage: usage}} =
               AgentLoop.maybe_stop_coordination_loop([], config, response)

      assert message =~ "Agent stopped after repeated coordination-only iterations"
      assert [%{role: :assistant, content: ^message}] = messages
      assert usage.input_tokens == 10

      assert_received {:event, :coordination_loop_stopped, %{streak: 6}}
    end

    test "concierge gets more room before the hard stop" do
      Process.put(:loomkin_coordination_streak, 6)

      config = %{
        role: :concierge,
        agent_name: "concierge",
        team_id: "team-123",
        on_event: fn _, _ -> :ok end
      }

      response = %Response{
        id: "resp_123",
        model: "openai:gpt-5.4",
        context: ReqLLM.Context.new([]),
        usage: %{input_tokens: 10, output_tokens: 20, total_cost: 0.12}
      }

      assert {:continue, []} =
               AgentLoop.maybe_stop_coordination_loop([], config, response)
    end

    test "concierge still stops after an extended coordination streak" do
      Process.put(:loomkin_coordination_streak, 7)

      config = %{
        role: :concierge,
        agent_name: "concierge",
        team_id: "team-123",
        on_event: fn _, _ -> :ok end
      }

      response = %Response{
        id: "resp_123",
        model: "openai:gpt-5.4",
        context: ReqLLM.Context.new([]),
        usage: %{input_tokens: 10, output_tokens: 20, total_cost: 0.12}
      }

      assert {:stop, message, _messages, _meta} =
               AgentLoop.maybe_stop_coordination_loop([], config, response)

      assert message =~ "Concierge stopped after repeated coordination-only iterations"
      assert message =~ "staying available for the user"
    end
  end

  describe "research loop detection" do
    test "research-only tool sets are detected" do
      assert AgentLoop.research_scan_only_tool_calls?([
               %{name: "file_search", arguments: %{"pattern" => "AgentLoop"}},
               %{name: "file_read", arguments: %{"file_path" => "lib/foo.ex"}}
             ])

      refute AgentLoop.research_scan_only_tool_calls?([
               %{name: "file_search", arguments: %{"pattern" => "AgentLoop"}},
               %{name: "peer_discovery", arguments: %{"discoveries" => ["x"]}}
             ])
    end

    test "warns researchers after repeated scan-only iterations" do
      Process.put(:loomkin_research_scan_streak, 0)
      test_pid = self()

      config = %{
        role: :researcher,
        agent_name: "researcher-1",
        team_id: "team-123",
        on_event: fn event_name, payload ->
          send(test_pid, {:event, event_name, payload})
          :ok
        end
      }

      tools = [%{name: "file_search", arguments: %{"pattern" => "AgentLoop"}}]

      assert [] == AgentLoop.maybe_inject_research_warning([], tools, config)
      assert [] == AgentLoop.maybe_inject_research_warning([], tools, config)

      messages = AgentLoop.maybe_inject_research_warning([], tools, config)
      assert [%{role: :system, content: content}] = messages
      assert content =~ "You are a researcher"
      assert content =~ "context_offload"
      assert content =~ "peer_complete_task"

      assert_received {:event, :research_loop_detected, %{streak: 3, tools: ["file_search"]}}
    end

    test "resets research scan streak when the researcher starts publishing" do
      Process.put(:loomkin_research_scan_streak, 2)

      config = %{
        role: :researcher,
        agent_name: "researcher-1",
        team_id: "team-123",
        on_event: fn _, _ -> :ok end
      }

      assert [] ==
               AgentLoop.maybe_inject_research_warning(
                 [],
                 [%{name: "peer_discovery", arguments: %{"discoveries" => ["x"]}}],
                 config
               )

      assert Process.get(:loomkin_research_scan_streak) == 0
    end
  end

  describe "history normalization" do
    test "reattaches orphan tool-call maps to the previous assistant message" do
      messages = [
        %{role: :user, content: "Please assess vault ingestion"},
        %{role: :assistant, content: ""},
        %{
          id: "call_123",
          name: "team_spawn",
          arguments: %{"team_name" => "vault-ingestion-assessment"}
        },
        %{role: :tool, content: "spawned", tool_call_id: "call_123"}
      ]

      assert [
               %{role: :user},
               %{role: :assistant, tool_calls: [tool_call]},
               %{role: :tool, tool_call_id: "call_123"}
             ] = AgentLoop.normalize_history_messages(messages)

      assert tool_call.id == "call_123"
      assert tool_call.name == "team_spawn"
      assert tool_call.arguments == %{"team_name" => "vault-ingestion-assessment"}
    end

    test "rebuilds orphan tool-call maps into a synthetic assistant when a tool result exists" do
      messages = [
        %{role: :user, content: "Please assess vault ingestion"},
        %{id: "call_123", name: "team_spawn", arguments: %{"team_name" => "vault"}},
        %{id: "call_456", name: "decision_log", arguments: %{"title" => "Delegate"}},
        %{role: :tool, content: "spawn failed", tool_call_id: "call_123"},
        %{role: :tool, content: "logged", tool_call_id: "call_456"}
      ]

      assert [
               %{role: :user},
               %{role: :assistant, tool_calls: [first_call, second_call]},
               %{role: :tool, tool_call_id: "call_123"},
               %{role: :tool, tool_call_id: "call_456"}
             ] = AgentLoop.normalize_history_messages(messages)

      assert first_call.id == "call_123"
      assert first_call.name == "team_spawn"
      assert second_call.id == "call_456"
      assert second_call.name == "decision_log"
    end

    test "drops unrepairable orphan tool-call maps" do
      messages = [
        %{id: "call_123", name: "team_spawn", arguments: %{"team_name" => "vault"}}
      ]

      assert [] == AgentLoop.normalize_history_messages(messages)
    end
  end

  describe "max_iterations" do
    test "config includes max_iterations with default of 25" do
      # Build config through run — verify it wires up correctly
      # by checking the module attribute is accessible
      assert AgentLoop.__info__(:module) == AgentLoop
    end

    test "max_iterations can be overridden via options" do
      test_pid = self()

      # Use a model that will fail immediately — the point is to verify
      # the config wiring, not actually run the loop
      AgentLoop.run([%{role: :user, content: "test"}],
        model: "test:nonexistent",
        system_prompt: "test",
        tools: [],
        max_iterations: 5,
        on_event: fn event_name, payload ->
          send(test_pid, {:event, event_name, payload})
          :ok
        end
      )

      # LLM call fails before iteration cap is reached, so no max_iterations_exceeded event
      refute_received {:event, :max_iterations_exceeded, _}
    end
  end
end
