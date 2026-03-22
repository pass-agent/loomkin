defmodule Loomkin.Teams.AgentStateTest do
  use ExUnit.Case, async: true

  alias Loomkin.Teams.Agent
  alias Loomkin.Teams.AgentState
  alias Loomkin.Teams.Role

  defp build_agent_state(overrides \\ %{}) do
    defaults = %Agent{
      team_id: "team-abc",
      session_id: "sess-123",
      name: :coder,
      role: :coder,
      role_config: %Role{
        name: :coder,
        model_tier: :default,
        tools: [Loomkin.Tools.ReadFile, Loomkin.Tools.WriteFile],
        system_prompt: "You are a coder.",
        budget_limit: 1.0,
        reasoning_strategy: :react,
        healing_policy: %{enabled: true, categories: [:compile_error], min_severity: :medium}
      },
      status: :thinking,
      model: "claude-sonnet-4-20250514",
      project_path: "/tmp/test-project",
      system_prompt_extra: "Extra context here.",
      tools: [Loomkin.Tools.ReadFile, Loomkin.Tools.WriteFile],
      messages: [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ],
      task: %{id: "task-1", description: "Fix the bug"},
      context: %{"file.ex" => "contents"},
      cost_usd: 0.05,
      tokens_used: 1500,
      failure_count: 1,
      permission_mode: :auto,
      pending_permission: nil,
      loop_task: %Task{
        pid: self(),
        ref: make_ref(),
        owner: self(),
        mfa: {__MODULE__, :build_agent_state, 1}
      },
      pending_updates: [%{type: :context_update, data: "new data"}],
      priority_queue: [%{priority: :urgent, content: "fix now"}],
      pause_requested: true,
      pause_queued: false,
      paused_state: %{messages: [%{role: "user", content: "paused msg"}]},
      frozen_state: nil,
      healing_queue: [%{category: :compile_error, detail: "undefined function"}],
      subscription_ids: [make_ref(), make_ref()],
      last_asked_at: ~U[2026-03-19 10:00:00Z],
      pending_ask_user: "What should I do?",
      spawned_child_teams: ["sub-team-1"],
      auto_approve_spawns: true,
      wake_ref: nil
    }

    Map.merge(defaults, overrides)
  end

  describe "extract_essential_state/1" do
    test "extracts all essential fields from agent state" do
      agent = build_agent_state()
      essential = AgentState.extract_essential_state(agent)

      assert %AgentState{} = essential
      assert essential.team_id == "team-abc"
      assert essential.session_id == "sess-123"
      assert essential.name == :coder
      assert essential.role == :coder
      assert %Role{name: :coder} = essential.role_config
      assert essential.status == :thinking
      assert essential.model == "claude-sonnet-4-20250514"
      assert essential.project_path == "/tmp/test-project"
      assert essential.system_prompt_extra == "Extra context here."
      assert length(essential.messages) == 2
      assert essential.task == %{id: "task-1", description: "Fix the bug"}
      assert essential.context == %{"file.ex" => "contents"}
      assert essential.cost_usd == 0.05
      assert essential.tokens_used == 1500
      assert essential.failure_count == 1
      assert essential.permission_mode == :auto
      assert essential.pause_requested == true
      assert essential.paused_state == %{messages: [%{role: "user", content: "paused msg"}]}

      assert essential.healing_queue == [
               %{category: :compile_error, detail: "undefined function"}
             ]

      assert essential.spawned_child_teams == ["sub-team-1"]
      assert essential.auto_approve_spawns == true
    end

    test "excludes transient process references" do
      agent = build_agent_state()
      essential = AgentState.extract_essential_state(agent)

      refute Map.has_key?(Map.from_struct(essential), :loop_task)
      refute Map.has_key?(Map.from_struct(essential), :subscription_ids)
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trip preserves all fields" do
      agent = build_agent_state()
      essential = AgentState.extract_essential_state(agent)

      binary = AgentState.serialize(essential)
      assert is_binary(binary)
      assert byte_size(binary) > 0

      assert {:ok, restored} = AgentState.deserialize(binary)
      assert restored == essential
    end

    test "round-trip preserves complex nested data" do
      agent =
        build_agent_state(%{
          context: %{
            "nested" => %{"deep" => [1, 2, 3]},
            "list" => ["a", "b"]
          },
          priority_queue: [
            %{priority: :urgent, content: "first"},
            %{priority: :normal, content: "second"}
          ]
        })

      essential = AgentState.extract_essential_state(agent)
      binary = AgentState.serialize(essential)
      assert {:ok, restored} = AgentState.deserialize(binary)

      assert restored.context == %{
               "nested" => %{"deep" => [1, 2, 3]},
               "list" => ["a", "b"]
             }

      assert length(restored.priority_queue) == 2
    end

    test "round-trip preserves paused_state and frozen_state" do
      agent =
        build_agent_state(%{
          paused_state: %{
            messages: [%{role: "user", content: "mid-execution"}],
            iteration: 3
          },
          frozen_state: %{
            error: "compile error in app.ex",
            healing_attempt: 1
          }
        })

      essential = AgentState.extract_essential_state(agent)
      binary = AgentState.serialize(essential)
      assert {:ok, restored} = AgentState.deserialize(binary)

      assert restored.paused_state == essential.paused_state
      assert restored.frozen_state == essential.frozen_state
    end

    test "deserialize returns error for invalid binary" do
      assert {:error, :invalid_binary} = AgentState.deserialize(<<0, 1, 2, 3>>)
    end

    test "deserialize returns error for empty binary" do
      assert {:error, :invalid_binary} = AgentState.deserialize(<<>>)
    end
  end

  describe "merge_into_init/2" do
    test "produces keyword opts suitable for Agent.start_link" do
      agent = build_agent_state()
      essential = AgentState.extract_essential_state(agent)

      opts = AgentState.merge_into_init(essential)

      assert Keyword.get(opts, :team_id) == "team-abc"
      assert Keyword.get(opts, :session_id) == "sess-123"
      assert Keyword.get(opts, :name) == :coder
      assert Keyword.get(opts, :role) == :coder
      assert %Role{} = Keyword.get(opts, :role_config)
      assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
      assert Keyword.get(opts, :project_path) == "/tmp/test-project"
      assert Keyword.get(opts, :permission_mode) == :auto
    end

    test "caller-provided opts override restored values" do
      agent = build_agent_state()
      essential = AgentState.extract_essential_state(agent)

      opts = AgentState.merge_into_init(essential, model: "gpt-4o", project_path: "/new/path")

      assert Keyword.get(opts, :model) == "gpt-4o"
      assert Keyword.get(opts, :project_path) == "/new/path"
      # Non-overridden fields are preserved
      assert Keyword.get(opts, :team_id) == "team-abc"
    end
  end

  describe "restore_into_agent/2" do
    test "merges restorable fields into a fresh agent" do
      # Simulate a fresh agent from init (minimal state)
      fresh = %Agent{
        team_id: "team-abc",
        session_id: "sess-new",
        name: :coder,
        role: :coder,
        role_config: %Role{
          name: :coder,
          model_tier: :default,
          tools: [Loomkin.Tools.ReadFile],
          system_prompt: "Fresh prompt.",
          budget_limit: 2.0,
          reasoning_strategy: :react,
          healing_policy: %{}
        },
        status: :idle,
        model: "claude-sonnet-4-20250514",
        project_path: "/tmp/fresh-project",
        tools: [Loomkin.Tools.ReadFile],
        messages: [],
        subscription_ids: [make_ref()]
      }

      # Simulate a checkpoint essential state with accumulated work
      checkpoint_agent = build_agent_state()
      essential = AgentState.extract_essential_state(checkpoint_agent)

      restored = AgentState.restore_into_agent(fresh, essential)

      # Restorable fields come from checkpoint
      assert length(restored.messages) == 2
      assert restored.task == %{id: "task-1", description: "Fix the bug"}
      assert restored.context == %{"file.ex" => "contents"}
      assert restored.cost_usd == 0.05
      assert restored.tokens_used == 1500
      assert restored.failure_count == 1
      assert restored.spawned_child_teams == ["sub-team-1"]
      assert restored.auto_approve_spawns == true
      assert restored.paused_state == %{messages: [%{role: "user", content: "paused msg"}]}

      # Identity and config stay from fresh init
      assert restored.team_id == "team-abc"
      assert restored.session_id == "sess-new"
      assert restored.role_config.system_prompt == "Fresh prompt."
      assert restored.project_path == "/tmp/fresh-project"

      # Transient fields stay from fresh init
      assert length(restored.subscription_ids) == 1
    end

    test "handles empty checkpoint gracefully" do
      fresh = %Agent{
        team_id: "team-abc",
        name: :coder,
        role: :coder,
        status: :idle,
        messages: [%{role: "system", content: "init"}]
      }

      empty_essential = %AgentState{
        team_id: "team-abc",
        name: :coder,
        role: :coder,
        messages: [],
        context: %{},
        cost_usd: 0.0,
        tokens_used: 0,
        failure_count: 0
      }

      restored = AgentState.restore_into_agent(fresh, empty_essential)

      # Empty checkpoint restores empty state
      assert restored.messages == []
      assert restored.context == %{}
      assert restored.cost_usd == 0.0
    end
  end

  describe "essential_fields/0" do
    test "returns a list of atoms" do
      fields = AgentState.essential_fields()
      assert is_list(fields)
      assert Enum.all?(fields, &is_atom/1)
      assert :messages in fields
      assert :paused_state in fields
      assert :frozen_state in fields
    end

    test "does not include transient fields" do
      fields = AgentState.essential_fields()
      refute :loop_task in fields
      refute :subscription_ids in fields
    end
  end
end
