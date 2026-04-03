defmodule Loomkin.Permissions.TrustPolicyTest do
  use ExUnit.Case, async: true

  alias Loomkin.Permissions.TrustPolicy

  setup do
    session_id = Ecto.UUID.generate()
    TrustPolicy.init(session_id)
    on_exit(fn -> TrustPolicy.cleanup(session_id) end)
    %{session_id: session_id}
  end

  describe "init/1" do
    test "creates an ETS table for the session" do
      sid = Ecto.UUID.generate()
      assert TrustPolicy.init(sid) == :ok
      table_name = :"trust_policies_#{sid}"
      assert :ets.info(table_name) != :undefined
      TrustPolicy.cleanup(sid)
    end
  end

  describe "cleanup/1" do
    test "removes the ETS table", %{session_id: session_id} do
      table_name = :"trust_policies_#{session_id}"
      assert :ets.info(table_name) != :undefined

      assert TrustPolicy.cleanup(session_id) == :ok
      assert :ets.info(table_name) == :undefined
    end

    test "is idempotent for non-existent tables" do
      assert TrustPolicy.cleanup("nonexistent") == :ok
    end
  end

  describe "set_policy/2 and list_policies/1" do
    test "round-trips a policy", %{session_id: session_id} do
      policy = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "/src"
      }

      assert TrustPolicy.set_policy(session_id, policy) == :ok
      policies = TrustPolicy.list_policies(session_id)
      assert length(policies) == 1
      assert hd(policies) == policy
    end

    test "overwrites policy with same key", %{session_id: session_id} do
      policy1 = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :ask,
        scope: "*"
      }

      policy2 = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, policy1)
      TrustPolicy.set_policy(session_id, policy2)

      policies = TrustPolicy.list_policies(session_id)
      assert length(policies) == 1
      assert hd(policies).action == :auto_approve
    end

    test "stores multiple distinct policies", %{session_id: session_id} do
      p1 = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      p2 = %TrustPolicy{
        agent_name: "reviewer",
        role: :any,
        tool_category: :read,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, p1)
      TrustPolicy.set_policy(session_id, p2)

      policies = TrustPolicy.list_policies(session_id)
      assert length(policies) == 2
    end

    test "returns empty list for non-existent table" do
      assert TrustPolicy.list_policies("nonexistent") == []
    end
  end

  describe "remove_policy/2" do
    test "removes a specific policy", %{session_id: session_id} do
      policy = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, policy)
      assert length(TrustPolicy.list_policies(session_id)) == 1

      assert TrustPolicy.remove_policy(session_id, policy) == :ok
      assert TrustPolicy.list_policies(session_id) == []
    end

    test "does not affect other policies", %{session_id: session_id} do
      p1 = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      p2 = %TrustPolicy{
        agent_name: "reviewer",
        role: :any,
        tool_category: :read,
        action: :ask,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, p1)
      TrustPolicy.set_policy(session_id, p2)

      TrustPolicy.remove_policy(session_id, p1)

      policies = TrustPolicy.list_policies(session_id)
      assert length(policies) == 1
      assert hd(policies).agent_name == "reviewer"
    end
  end

  describe "apply_preset/2" do
    test "applies :strict preset — asks for everything", %{session_id: session_id} do
      assert TrustPolicy.apply_preset(session_id, :strict) == :ok
      assert TrustPolicy.get_preset_name(session_id) == :strict

      policies = TrustPolicy.list_policies(session_id)
      assert length(policies) == 4

      Enum.each(policies, fn p ->
        assert p.action == :ask
        assert p.agent_name == "*"
      end)
    end

    test "applies :balanced preset — auto-approve read+coordination, ask write+execute", %{
      session_id: session_id
    } do
      assert TrustPolicy.apply_preset(session_id, :balanced) == :ok
      assert TrustPolicy.get_preset_name(session_id) == :balanced

      policies = TrustPolicy.list_policies(session_id)
      assert length(policies) == 4

      by_category = Map.new(policies, fn p -> {p.tool_category, p.action} end)
      assert by_category[:read] == :auto_approve
      assert by_category[:coordination] == :auto_approve
      assert by_category[:write] == :ask
      assert by_category[:execute] == :ask
    end

    test "applies :autonomous preset — auto-approve read+coordination+write, ask execute", %{
      session_id: session_id
    } do
      assert TrustPolicy.apply_preset(session_id, :autonomous) == :ok
      assert TrustPolicy.get_preset_name(session_id) == :autonomous

      policies = TrustPolicy.list_policies(session_id)
      by_category = Map.new(policies, fn p -> {p.tool_category, p.action} end)
      assert by_category[:read] == :auto_approve
      assert by_category[:coordination] == :auto_approve
      assert by_category[:write] == :auto_approve
      assert by_category[:execute] == :ask
    end

    test "applies :full_trust preset — auto-approve everything", %{session_id: session_id} do
      assert TrustPolicy.apply_preset(session_id, :full_trust) == :ok
      assert TrustPolicy.get_preset_name(session_id) == :full_trust

      policies = TrustPolicy.list_policies(session_id)
      assert length(policies) == 1
      assert hd(policies).tool_category == :all
      assert hd(policies).action == :auto_approve
    end

    test "clears previous policies when applying a preset", %{session_id: session_id} do
      custom = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :execute,
        action: :deny,
        scope: "/dangerous"
      }

      TrustPolicy.set_policy(session_id, custom)
      TrustPolicy.apply_preset(session_id, :balanced)

      policies = TrustPolicy.list_policies(session_id)

      refute Enum.any?(policies, fn p -> p.agent_name == "coder" end)
    end

    test "returns error for unknown preset", %{session_id: session_id} do
      assert TrustPolicy.apply_preset(session_id, :nonexistent) == {:error, :unknown_preset}
    end
  end

  describe "apply_preset_for_agent/3" do
    test "applies preset scoped to one agent without clearing others", %{
      session_id: session_id
    } do
      # Set a global balanced preset first
      TrustPolicy.apply_preset(session_id, :balanced)
      global_count = length(TrustPolicy.list_policies(session_id))

      # Apply full_trust for a specific agent
      assert TrustPolicy.apply_preset_for_agent(session_id, "coder", :full_trust) == :ok

      policies = TrustPolicy.list_policies(session_id)
      coder_policies = Enum.filter(policies, fn p -> p.agent_name == "coder" end)
      global_policies = Enum.filter(policies, fn p -> p.agent_name == "*" end)

      assert length(coder_policies) == 1
      assert hd(coder_policies).action == :auto_approve
      assert hd(coder_policies).tool_category == :all

      # Global policies remain intact
      assert length(global_policies) == global_count
    end

    test "returns error for unknown preset" do
      sid = Ecto.UUID.generate()
      TrustPolicy.init(sid)

      assert TrustPolicy.apply_preset_for_agent(sid, "coder", :nonexistent) ==
               {:error, :unknown_preset}

      TrustPolicy.cleanup(sid)
    end
  end

  describe "check/5" do
    test "returns nil when no policies exist", %{session_id: session_id} do
      assert TrustPolicy.check(session_id, "coder", :coder, "file_read", "/src/app.ex") == nil
    end

    test "returns nil when table does not exist" do
      assert TrustPolicy.check("nonexistent", "coder", :coder, "file_read", "/src/app.ex") == nil
    end

    test "matches exact agent + exact category + exact scope (priority 1)", %{
      session_id: session_id
    } do
      policy = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :deny,
        scope: "/secrets"
      }

      TrustPolicy.set_policy(session_id, policy)

      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/secrets") == :deny
    end

    test "matches exact agent + exact category + wildcard scope (priority 2)", %{
      session_id: session_id
    } do
      policy = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, policy)

      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/any/path") ==
               :auto_approve
    end

    test "matches exact agent + :all category (priority 3)", %{session_id: session_id} do
      policy = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :all,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, policy)

      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/any") ==
               :auto_approve

      assert TrustPolicy.check(session_id, "coder", :coder, "shell", "/any") == :auto_approve
      assert TrustPolicy.check(session_id, "coder", :coder, "file_read", "/any") == :auto_approve
    end

    test "matches wildcard agent + exact category (priority 6)", %{session_id: session_id} do
      policy = %TrustPolicy{
        agent_name: "*",
        role: :any,
        tool_category: :execute,
        action: :deny,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, policy)

      assert TrustPolicy.check(session_id, "any_agent", :coder, "shell", "/any") == :deny
      assert TrustPolicy.check(session_id, "another", :reviewer, "git", "/any") == :deny
    end

    test "matches wildcard agent + :all category (priority 7)", %{session_id: session_id} do
      policy = %TrustPolicy{
        agent_name: "*",
        role: :any,
        tool_category: :all,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, policy)

      assert TrustPolicy.check(session_id, "any_agent", :coder, "file_write", "/any") ==
               :auto_approve

      assert TrustPolicy.check(session_id, "any_agent", :coder, "shell", "/any") == :auto_approve
    end

    test "agent-specific policy beats wildcard policy", %{session_id: session_id} do
      # Wildcard: deny all execute
      wildcard = %TrustPolicy{
        agent_name: "*",
        role: :any,
        tool_category: :execute,
        action: :deny,
        scope: "*"
      }

      # Agent-specific: auto-approve execute for coder
      agent_specific = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :execute,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, wildcard)
      TrustPolicy.set_policy(session_id, agent_specific)

      # Coder gets auto_approve (agent-specific wins)
      assert TrustPolicy.check(session_id, "coder", :coder, "shell", "/any") == :auto_approve

      # Other agents get deny (wildcard applies)
      assert TrustPolicy.check(session_id, "researcher", :researcher, "shell", "/any") == :deny
    end

    test "exact scope beats wildcard scope for same agent", %{session_id: session_id} do
      # Wildcard scope: auto-approve writes
      general = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      # Exact scope: deny writes to /secrets
      exact = %TrustPolicy{
        agent_name: "coder",
        role: :any,
        tool_category: :write,
        action: :deny,
        scope: "/secrets"
      }

      TrustPolicy.set_policy(session_id, general)
      TrustPolicy.set_policy(session_id, exact)

      # Exact scope wins for /secrets
      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/secrets") == :deny

      # Wildcard scope applies elsewhere
      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/src") ==
               :auto_approve
    end

    test "balanced preset auto-approves reads, asks for writes", %{session_id: session_id} do
      TrustPolicy.apply_preset(session_id, :balanced)

      assert TrustPolicy.check(session_id, "coder", :coder, "file_read", "/src") == :auto_approve

      assert TrustPolicy.check(session_id, "coder", :coder, "content_search", "/src") ==
               :auto_approve

      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/src") == :ask
      assert TrustPolicy.check(session_id, "coder", :coder, "shell", "/src") == :ask

      assert TrustPolicy.check(session_id, "coder", :coder, "team_spawn", "/src") ==
               :auto_approve
    end

    test "strict preset asks for everything", %{session_id: session_id} do
      TrustPolicy.apply_preset(session_id, :strict)

      assert TrustPolicy.check(session_id, "coder", :coder, "file_read", "/src") == :ask
      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/src") == :ask
      assert TrustPolicy.check(session_id, "coder", :coder, "shell", "/src") == :ask
      assert TrustPolicy.check(session_id, "coder", :coder, "team_spawn", "/src") == :ask
    end

    test "full_trust preset auto-approves everything", %{session_id: session_id} do
      TrustPolicy.apply_preset(session_id, :full_trust)

      assert TrustPolicy.check(session_id, "coder", :coder, "file_read", "/src") == :auto_approve

      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/src") ==
               :auto_approve

      assert TrustPolicy.check(session_id, "coder", :coder, "shell", "/src") == :auto_approve

      assert TrustPolicy.check(session_id, "coder", :coder, "team_spawn", "/src") ==
               :auto_approve
    end

    test "autonomous preset auto-approves write but asks for execute", %{
      session_id: session_id
    } do
      TrustPolicy.apply_preset(session_id, :autonomous)

      assert TrustPolicy.check(session_id, "coder", :coder, "file_write", "/src") ==
               :auto_approve

      assert TrustPolicy.check(session_id, "coder", :coder, "shell", "/src") == :ask
    end

    test "returns nil for unknown tool category when no :all policy exists", %{
      session_id: session_id
    } do
      policy = %TrustPolicy{
        agent_name: "*",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, policy)

      # "unknown_tool" has :unknown category — no policy matches
      assert TrustPolicy.check(session_id, "coder", :coder, "unknown_tool", "/any") == nil
    end
  end

  describe "get_preset_name/1" do
    test "returns nil when no preset is active", %{session_id: session_id} do
      assert TrustPolicy.get_preset_name(session_id) == nil
    end

    test "returns preset name after applying preset", %{session_id: session_id} do
      TrustPolicy.apply_preset(session_id, :balanced)
      assert TrustPolicy.get_preset_name(session_id) == :balanced
    end

    test "returns nil for non-existent table" do
      assert TrustPolicy.get_preset_name("nonexistent") == nil
    end

    test "updates when preset changes", %{session_id: session_id} do
      TrustPolicy.apply_preset(session_id, :balanced)
      assert TrustPolicy.get_preset_name(session_id) == :balanced

      TrustPolicy.apply_preset(session_id, :strict)
      assert TrustPolicy.get_preset_name(session_id) == :strict
    end
  end

  describe "role-based matching" do
    test "matches role-specific policy with wildcard agent (priority 4-5)", %{
      session_id: session_id
    } do
      policy = %TrustPolicy{
        agent_name: "*",
        role: :coder,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, policy)

      # Coder role matches
      assert TrustPolicy.check(session_id, "any_agent", :coder, "file_write", "/src") ==
               :auto_approve

      # Reviewer role does not match
      assert TrustPolicy.check(session_id, "any_agent", :reviewer, "file_write", "/src") == nil
    end

    test "agent-specific policy takes priority over role-based policy", %{
      session_id: session_id
    } do
      role_policy = %TrustPolicy{
        agent_name: "*",
        role: :coder,
        tool_category: :write,
        action: :ask,
        scope: "*"
      }

      agent_policy = %TrustPolicy{
        agent_name: "senior-coder",
        role: :any,
        tool_category: :write,
        action: :auto_approve,
        scope: "*"
      }

      TrustPolicy.set_policy(session_id, role_policy)
      TrustPolicy.set_policy(session_id, agent_policy)

      # Agent-specific wins for senior-coder
      assert TrustPolicy.check(session_id, "senior-coder", :coder, "file_write", "/src") ==
               :auto_approve

      # Role policy applies to other coders
      assert TrustPolicy.check(session_id, "junior-coder", :coder, "file_write", "/src") == :ask
    end
  end
end
