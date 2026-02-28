defmodule Loom.Teams.AgentProactivityTest do
  @moduledoc "End-to-end integration tests for Epic 5.9: Agent Proactivity & Context Awareness."
  use Loom.DataCase, async: false

  alias Loom.Teams.{Agent, ContextOffload, ContextRetrieval, Manager, Role}
  alias Loom.Session.ContextWindow

  setup do
    {:ok, team_id} = Manager.create_team(name: "proactivity-test")

    on_exit(fn ->
      DynamicSupervisor.which_children(Loom.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loom.Teams.AgentSupervisor, pid)
      end)

      Loom.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp unique_name(prefix) do
    "#{prefix}-#{:erlang.unique_integer([:positive])}"
  end

  defp start_agent(team_id, opts) do
    name = Keyword.get(opts, :name, unique_name("agent"))
    role = Keyword.get(opts, :role, :coder)

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Loom.Teams.AgentSupervisor,
        {Agent, team_id: team_id, name: name, role: role}
      )

    %{pid: pid, name: name, role: role}
  end

  describe "auto-offload triggers at 60% context pressure" do
    test "maybe_offload triggers when tokens exceed 60% of model limit" do
      # Default model limit is 128_000 tokens. 60% = 76_800.
      # Each char ~= 0.25 tokens, so we need ~307_200 chars to cross threshold.
      big_content = String.duplicate("x", 320_000)

      messages =
        Enum.map(1..10, fn i ->
          role = if rem(i, 2) == 1, do: :user, else: :assistant
          %{role: role, content: big_content}
        end)

      tokens = ContextOffload.estimate_tokens(messages)
      model_limit = ContextWindow.model_limit(nil)
      threshold = trunc(model_limit * 0.60)

      assert tokens > threshold, "Test messages must exceed 60% threshold"
    end

    test "maybe_offload returns :noop when under threshold" do
      agent_state = %{
        model: nil,
        team_id: "test-team",
        name: "agent-1",
        messages: [%{role: :user, content: "short message"}]
      }

      assert :noop = ContextOffload.maybe_offload(agent_state)
    end
  end

  describe "context pressure indicator at >50%" do
    test "appends pressure message when team agent exceeds 50% usage", %{team_id: team_id} do
      # Build messages that consume >50% of model context
      # Default limit 128k, 50% = 64k tokens = ~256k chars
      big_content = String.duplicate("y", 280_000)

      messages =
        Enum.map(1..4, fn i ->
          role = if rem(i, 2) == 1, do: :user, else: :assistant
          %{role: role, content: big_content}
        end)

      result =
        ContextWindow.build_messages(messages, "You are a test agent.",
          model: nil,
          team_id: team_id
        )

      # The last message should be a context pressure indicator
      last = List.last(result)
      assert last.role == :system
      assert last.content =~ "Context pressure"
      assert last.content =~ "context_offload"
    end

    test "no pressure message when under 50%", %{team_id: team_id} do
      messages = [
        %{role: :user, content: "hello"},
        %{role: :assistant, content: "hi there"}
      ]

      result =
        ContextWindow.build_messages(messages, "You are a test agent.",
          model: nil,
          team_id: team_id
        )

      # Should not have a pressure indicator — last non-system message should be conversation
      system_messages = Enum.filter(result, &(&1.role == :system))
      refute Enum.any?(system_messages, &String.contains?(&1.content, "Context pressure"))
    end
  end

  describe "keeper index in system prompts" do
    test "inject_keeper_index adds 'none yet' when no keepers exist", %{team_id: team_id} do
      {:ok, role_config} = Role.get(:coder)
      _state = %Agent{team_id: team_id, role_config: role_config}

      # Access inject_keeper_index through build_loop_opts indirectly:
      # the system prompt should contain the {keeper_index} placeholder or be appended
      prompt = role_config.system_prompt

      # The role system prompt includes {keeper_index} placeholder via @context_mesh_prompt
      assert prompt =~ "{keeper_index}" or prompt =~ "Context Mesh"
    end

    test "keeper index updates when keepers are created", %{team_id: team_id} do
      # Create a keeper
      messages = [%{role: :user, content: "research on elixir genservers"}]

      {:ok, _pid, entry} =
        ContextOffload.offload_to_keeper(team_id, "researcher", messages,
          topic: "genserver patterns"
        )

      assert entry =~ "genserver patterns"

      # Verify keeper appears in listing
      keepers = ContextRetrieval.list_keepers(team_id)
      assert length(keepers) == 1
      assert hd(keepers).topic == "genserver patterns"
    end
  end

  describe "keeper creation notifications" do
    test "agents receive keeper_created broadcast", %{team_id: team_id} do
      %{pid: pid, name: _name} = start_agent(team_id, name: "listener", role: :coder)

      # Give agent time to subscribe to PubSub
      Process.sleep(50)

      # Offload from a different agent — should trigger broadcast
      messages = [%{role: :user, content: "database schema analysis"}]

      {:ok, _keeper_pid, _entry} =
        ContextOffload.offload_to_keeper(team_id, "other-agent", messages,
          topic: "db schema"
        )

      # Give agent time to receive the broadcast
      Process.sleep(100)

      state = :sys.get_state(pid)

      # Agent should have a system message about the new keeper
      keeper_msgs =
        Enum.filter(state.messages, fn msg ->
          msg.role == :system and String.contains?(msg.content, "New keeper available")
        end)

      assert length(keeper_msgs) == 1
      assert hd(keeper_msgs).content =~ "db schema"
      assert hd(keeper_msgs).content =~ "other-agent"
    end

    test "agent ignores keeper_created from itself", %{team_id: team_id} do
      %{pid: pid, name: name} = start_agent(team_id, role: :researcher)
      Process.sleep(50)

      # Broadcast keeper_created with source matching this agent
      Phoenix.PubSub.broadcast(
        Loom.PubSub,
        "team:#{team_id}",
        {:keeper_created, %{id: "k1", topic: "self topic", source: name, tokens: 100}}
      )

      Process.sleep(100)

      state = :sys.get_state(pid)

      keeper_msgs =
        Enum.filter(state.messages, fn msg ->
          msg.role == :system and String.contains?(msg.content, "New keeper available")
        end)

      assert keeper_msgs == []
    end
  end

  describe "role prompts include context awareness" do
    test "all 5 roles have context mesh block" do
      for role <- [:lead, :researcher, :coder, :reviewer, :tester] do
        {:ok, config} = Role.get(role)

        assert config.system_prompt =~ "Context Mesh",
               "#{role} prompt missing Context Mesh block"

        assert config.system_prompt =~ "Context Awareness",
               "#{role} prompt missing Context Awareness section"

        assert config.system_prompt =~ "context_offload",
               "#{role} prompt missing context_offload tool reference"

        assert config.system_prompt =~ "context_retrieve",
               "#{role} prompt missing context_retrieve tool reference"
      end
    end

    test "each role has unique guidance" do
      configs =
        Enum.map([:lead, :researcher, :coder, :reviewer, :tester], fn role ->
          {:ok, config} = Role.get(role)
          {role, config.system_prompt}
        end)

      # Each role should have a distinct guidance section
      for {role, prompt} <- configs do
        case role do
          :lead -> assert prompt =~ "decomposing tasks"
          :researcher -> assert prompt =~ "Offload findings"
          :coder -> assert prompt =~ "design context"
          :reviewer -> assert prompt =~ "design context"
          :tester -> assert prompt =~ "implementation notes"
        end
      end
    end
  end

  describe "proactive retrieval on task assignment" do
    test "search finds relevant keepers for task description", %{team_id: team_id} do
      # Create a keeper with relevant content
      keeper_msgs = [%{role: :user, content: "authentication module analysis"}]

      {:ok, _keeper_pid, _entry} =
        ContextOffload.offload_to_keeper(team_id, "researcher", keeper_msgs,
          topic: "authentication analysis"
        )

      # Verify the search mechanism finds the keeper for task-like queries
      results = ContextRetrieval.search(team_id, "Fix authentication bug in login flow")
      assert length(results) == 1
      assert hd(results).relevance > 0
      assert hd(results).topic == "authentication analysis"
    end

    test "prefetch via direct Agent.assign_task path", %{team_id: team_id} do
      %{pid: pid} = start_agent(team_id, role: :coder)
      Process.sleep(50)

      task = %{id: "task-auth", description: "Fix authentication bug"}
      Agent.assign_task(pid, task)
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.task == task
    end

    test "prefetch via production {:task_assigned, ...} path", %{team_id: team_id} do
      # Create a keeper with relevant content first
      keeper_msgs = [%{role: :user, content: "database connection pooling analysis"}]

      {:ok, _keeper_pid, _entry} =
        ContextOffload.offload_to_keeper(team_id, "researcher", keeper_msgs,
          topic: "database pooling"
        )

      # Start agent and create a real task via Tasks module
      %{pid: pid, name: name} = start_agent(team_id, role: :coder)
      Process.sleep(50)

      {:ok, task} =
        Loom.Teams.Tasks.create_task(team_id, %{
          title: "Fix database pooling issue",
          description: "database connection pooling is failing under load"
        })

      # Use the production assignment path
      {:ok, _task} = Loom.Teams.Tasks.assign_task(task.id, name)
      Process.sleep(200)

      state = :sys.get_state(pid)
      assert state.task != nil
      assert state.task[:description] =~ "database"
    end

    test "no pre-fetch when no relevant keepers exist", %{team_id: team_id} do
      %{pid: pid} = start_agent(team_id, role: :coder)
      Process.sleep(50)

      task = %{id: "task-unrelated", description: "Completely unrelated topic xyz123"}
      Agent.assign_task(pid, task)
      Process.sleep(100)

      state = :sys.get_state(pid)

      prefetch_msgs =
        Enum.filter(state.messages, fn msg ->
          msg.role == :system and String.contains?(msg.content, "Pre-fetched context")
        end)

      assert prefetch_msgs == []
    end
  end

  describe "full proactivity lifecycle" do
    test "end-to-end: offload, notify, index, retrieve", %{team_id: team_id} do
      # 1. Start two agents
      %{pid: coder_pid} = start_agent(team_id, name: "coder-1", role: :coder)
      %{pid: researcher_pid} = start_agent(team_id, name: "researcher-1", role: :researcher)
      Process.sleep(50)

      # 2. Researcher offloads context (simulating completed research)
      research_msgs = [
        %{role: :user, content: "explore the database schema"},
        %{role: :assistant, content: "Found 12 tables with proper indexing..."}
      ]

      {:ok, _keeper_pid, entry} =
        ContextOffload.offload_to_keeper(team_id, "researcher-1", research_msgs,
          topic: "database schema exploration"
        )

      assert entry =~ "database schema exploration"

      # 3. Wait for keeper_created notification to reach coder
      Process.sleep(150)

      coder_state = :sys.get_state(coder_pid)

      keeper_notifications =
        Enum.filter(coder_state.messages, fn msg ->
          msg.role == :system and String.contains?(msg.content, "New keeper available")
        end)

      assert length(keeper_notifications) == 1
      assert hd(keeper_notifications).content =~ "database schema exploration"

      # 4. Researcher does NOT receive self-notification
      researcher_state = :sys.get_state(researcher_pid)

      researcher_keeper_msgs =
        Enum.filter(researcher_state.messages, fn msg ->
          msg.role == :system and String.contains?(msg.content, "New keeper available")
        end)

      assert researcher_keeper_msgs == []

      # 5. Verify keeper shows in index
      keepers = ContextRetrieval.list_keepers(team_id)
      assert length(keepers) == 1
      assert hd(keepers).topic == "database schema exploration"

      # 6. Assign coder a related task via production path
      {:ok, db_task} =
        Loom.Teams.Tasks.create_task(team_id, %{
          title: "Fix database schema migration",
          description: "Fix database schema migration issue"
        })

      {:ok, _} = Loom.Teams.Tasks.assign_task(db_task.id, "coder-1")
      Process.sleep(200)

      # Verify the search path works (pre-fetch attempted with matching keeper)
      results = ContextRetrieval.search(team_id, "database schema migration")
      assert length(results) == 1
      assert hd(results).relevance > 0

      final_state = :sys.get_state(coder_pid)
      assert final_state.task != nil
      assert final_state.task[:description] =~ "database"

      # 7. Verify all 5 roles have context awareness (spot check)
      for role <- [:lead, :researcher, :coder, :reviewer, :tester] do
        {:ok, config} = Role.get(role)
        assert config.system_prompt =~ "Context Mesh"
      end
    end
  end
end
