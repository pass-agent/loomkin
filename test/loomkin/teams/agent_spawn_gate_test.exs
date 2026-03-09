defmodule Loomkin.Teams.AgentSpawnGateTest do
  use ExUnit.Case, async: true

  # Wave 0 stub pattern — all tests skipped until Plans 02-03 implement spawn gate
  @moduletag :skip

  # alias Loomkin.Teams.Agent

  # ---------------------------------------------------------------------------
  # check_spawn_budget handle_call
  # ---------------------------------------------------------------------------

  describe "check_spawn_budget: budget exceeded" do
    @tag :skip
    test "returns {:budget_exceeded, %{remaining: _, estimated: _}} when estimated cost exceeds remaining budget" do
      flunk("not implemented")
    end
  end

  describe "check_spawn_budget: budget ok" do
    @tag :skip
    test "returns :ok when remaining budget is above estimated cost" do
      flunk("not implemented")
    end
  end

  # ---------------------------------------------------------------------------
  # get_spawn_settings handle_call
  # ---------------------------------------------------------------------------

  describe "get_spawn_settings" do
    @tag :skip
    test "returns %{auto_approve_spawns: false} by default" do
      flunk("not implemented")
    end
  end

  # ---------------------------------------------------------------------------
  # set_auto_approve_spawns handle_call
  # ---------------------------------------------------------------------------

  describe "set_auto_approve_spawns" do
    @tag :skip
    test "sets auto_approve_spawns to true and is readable via :get_spawn_settings" do
      flunk("not implemented")
    end
  end

  # ---------------------------------------------------------------------------
  # spawn gate timeout auto-deny
  # Use very short timeout (50ms) to keep test fast
  # ---------------------------------------------------------------------------

  describe "spawn gate timeout auto-deny" do
    @tag :skip
    test "gate auto-denies after timeout_ms elapses without human response" do
      # timeout: 50 in tool params to avoid slow test
      flunk("not implemented")
    end
  end
end
