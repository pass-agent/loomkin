defmodule Loomkin.Orchestration.CostTrackerTest do
  use Loomkin.DataCase, async: false

  alias Ecto.UUID
  alias Loomkin.Orchestration.CostTracker
  alias Loomkin.Orchestration.CostTracker.PricingTable
  alias Loomkin.Orchestration.Schema.CostEvent

  setup do
    # The orchestration supervisor starts a singleton `CostTracker`. Allow it
    # to use this test's sandboxed Repo connection so its synchronous inserts
    # see our checkout.
    case Process.whereis(CostTracker) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Loomkin.Repo, self(), pid)
    end

    on_exit(fn -> Process.delete(:loomkin_epic_id) end)
    :ok
  end

  describe "pricing table" do
    test "exact-key lookup returns expected prices for known models" do
      assert {:ok, %{input_per_1m: i, output_per_1m: o}} =
               PricingTable.lookup("anthropic:claude-sonnet-4-5")

      assert Decimal.equal?(i, Decimal.new("3.00"))
      assert Decimal.equal?(o, Decimal.new("15.00"))
    end

    test "prefix lookup matches versioned variants" do
      assert {:ok, _} = PricingTable.lookup("anthropic:claude-sonnet-4-5-20260101")
    end

    test "unknown models return :error" do
      assert :error = PricingTable.lookup("acme:nonexistent-model")
      assert :error = PricingTable.lookup(nil)
    end
  end

  describe "price/3" do
    test "computes cost in USD for a known model" do
      # 1M input @ $3 + 1M output @ $15 = $18.00
      cost = CostTracker.price("anthropic:claude-sonnet-4-5", 1_000_000, 1_000_000)
      assert %Decimal{} = cost
      assert Decimal.equal?(Decimal.round(cost, 2), Decimal.new("18.00"))
    end

    test "returns nil for unknown models" do
      assert CostTracker.price("acme:nope", 100, 200) == nil
    end

    test "returns nil when model is nil" do
      assert CostTracker.price(nil, 100, 200) == nil
    end
  end

  describe "handle_event/4 attribution" do
    test "persists a cost row attributed to the meta epic_id" do
      epic_id = UUID.generate()

      :telemetry.execute(
        [:loomkin, :orchestration, :llm, :request, :stop],
        %{input_tokens: 1_000, output_tokens: 500, duration_ms: 42},
        %{epic_id: epic_id, model: "anthropic:claude-sonnet-4-5", status: :ok}
      )

      [row] = list_for(epic_id)
      assert row.model == "anthropic:claude-sonnet-4-5"
      assert row.input_tokens == 1_000
      assert row.output_tokens == 500
      assert %Decimal{} = row.cost_usd
    end

    test "falls back to Process dict when meta has no epic_id" do
      epic_id = UUID.generate()
      Process.put(:loomkin_epic_id, epic_id)

      :telemetry.execute(
        [:loomkin, :orchestration, :llm, :request, :stop],
        %{input_tokens: 10, output_tokens: 20},
        %{model: "anthropic:claude-sonnet-4-5", status: :ok}
      )

      assert [%CostEvent{epic_id: ^epic_id}] = list_for(epic_id)
    end

    test "records row with cost_usd: nil for unknown models" do
      epic_id = UUID.generate()

      :telemetry.execute(
        [:loomkin, :orchestration, :llm, :request, :stop],
        %{input_tokens: 100, output_tokens: 200},
        %{epic_id: epic_id, model: "acme:nonexistent", status: :ok}
      )

      [row] = list_for(epic_id)
      assert row.cost_usd == nil
      assert row.input_tokens == 100
      assert row.output_tokens == 200
    end

    test "swallows errors — never raises out of telemetry" do
      # Passing a non-binary epic_id and malformed measurements should not
      # crash the handler.
      assert :ok =
               CostTracker.handle_event(
                 [:loomkin, :orchestration, :llm, :request, :stop],
                 %{},
                 %{epic_id: :not_a_string, model: "anthropic:claude-sonnet-4-5"},
                 nil
               )
    end
  end

  defp list_for(epic_id) do
    import Ecto.Query, only: [from: 2]

    Loomkin.Repo.all(from c in CostEvent, where: c.epic_id == ^epic_id)
  end
end
