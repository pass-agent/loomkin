defmodule Loomkin.Orchestration.ReviewerCrossModelTest do
  @moduledoc """
  Covers `Loomkin.Orchestration.Reviewer.resolve_model/2`:

    * backward compatible single-arity form still resolves to the
      configured default,
    * cross-model resolution picks the first pool entry that differs
      from the writer's model,
    * pool of size 1 (no alternative) logs a warning and degrades to
      the configured default instead of crashing.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Loomkin.Orchestration.Reviewer

  defmodule NoModelReviewer do
    @moduledoc false
    @behaviour Reviewer
    def name, do: :no_model_reviewer
    def rubric, do: "rubric"
    def review(_payload), do: {:ok, %Loomkin.Orchestration.Schema.ReviewVerdict{}}
  end

  defmodule OverrideReviewer do
    @moduledoc false
    @behaviour Reviewer
    def name, do: :override_reviewer
    def rubric, do: "rubric"
    def model, do: "openai:gpt-pinned"
    def review(_payload), do: {:ok, %Loomkin.Orchestration.Schema.ReviewVerdict{}}
  end

  setup do
    prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])
    on_exit(fn -> Application.put_env(:loomkin, Loomkin.Orchestration, prev) end)
    :ok
  end

  defp put_orch(opts) do
    prev = Application.get_env(:loomkin, Loomkin.Orchestration, [])
    Application.put_env(:loomkin, Loomkin.Orchestration, Keyword.merge(prev, opts))
  end

  describe "backward compatibility" do
    test "resolve_model/1 falls back to configured default" do
      put_orch(default_model: "anthropic:claude-sonnet-4-5")
      assert Reviewer.resolve_model(NoModelReviewer) == "anthropic:claude-sonnet-4-5"
    end

    test "resolve_model/2 with nil writer_model behaves like /1" do
      put_orch(default_model: "anthropic:claude-sonnet-4-5")
      assert Reviewer.resolve_model(NoModelReviewer, nil) == "anthropic:claude-sonnet-4-5"
    end

    test "explicit reviewer .model() override always wins, even with cross_model on" do
      put_orch(
        default_model: "anthropic:claude-sonnet-4-5",
        cross_model: true,
        reviewer_model_pool: ["openai:gpt-4o", "google_oauth:gemini-2.5-flash"]
      )

      # Even when the writer matches the override, the explicit pin holds.
      assert Reviewer.resolve_model(OverrideReviewer, "openai:gpt-pinned") ==
               "openai:gpt-pinned"
    end

    test "cross_model defaults to off and yields the default model" do
      put_orch(
        default_model: "anthropic:claude-sonnet-4-5",
        reviewer_model_pool: ["openai:gpt-4o", "google_oauth:gemini-2.5-flash"]
      )

      assert Reviewer.resolve_model(NoModelReviewer, "anthropic:claude-sonnet-4-5") ==
               "anthropic:claude-sonnet-4-5"
    end
  end

  describe "cross_model: true" do
    test "picks first pool entry that differs from the writer model" do
      put_orch(
        default_model: "anthropic:claude-sonnet-4-5",
        cross_model: true,
        reviewer_model_pool: [
          "anthropic:claude-sonnet-4-5",
          "google_oauth:gemini-2.5-flash",
          "openai:gpt-4o"
        ]
      )

      assert Reviewer.resolve_model(NoModelReviewer, "anthropic:claude-sonnet-4-5") ==
               "google_oauth:gemini-2.5-flash"
    end

    test "skips writer model even if it appears later in the pool" do
      put_orch(
        default_model: "anthropic:claude-sonnet-4-5",
        cross_model: true,
        reviewer_model_pool: [
          "google_oauth:gemini-2.5-flash",
          "anthropic:claude-sonnet-4-5",
          "openai:gpt-4o"
        ]
      )

      assert Reviewer.resolve_model(NoModelReviewer, "google_oauth:gemini-2.5-flash") ==
               "anthropic:claude-sonnet-4-5"
    end
  end

  describe "graceful degradation" do
    test "pool of size 1 matching writer logs warning and returns default" do
      put_orch(
        default_model: "anthropic:claude-sonnet-4-5",
        cross_model: true,
        reviewer_model_pool: ["anthropic:claude-sonnet-4-5"]
      )

      log =
        capture_log(fn ->
          assert Reviewer.resolve_model(NoModelReviewer, "anthropic:claude-sonnet-4-5") ==
                   "anthropic:claude-sonnet-4-5"
        end)

      assert log =~ "cross_model requested but no alternative available"
    end

    test "empty pool logs warning and returns default" do
      put_orch(
        default_model: "anthropic:claude-sonnet-4-5",
        cross_model: true,
        reviewer_model_pool: []
      )

      log =
        capture_log(fn ->
          assert Reviewer.resolve_model(NoModelReviewer, "anthropic:claude-sonnet-4-5") ==
                   "anthropic:claude-sonnet-4-5"
        end)

      assert log =~ "cross_model requested but no alternative available"
    end
  end
end
