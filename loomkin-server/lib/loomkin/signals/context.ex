defmodule Loomkin.Signals.Context do
  @moduledoc "Context-domain signals: updates, offloads, keeper creation."

  defmodule Update do
    use Jido.Signal,
      type: "context.update",
      schema: [
        from: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule Offloaded do
    use Jido.Signal,
      type: "context.offloaded",
      schema: [
        agent_name: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule KeeperCreated do
    use Jido.Signal,
      type: "context.keeper.created",
      schema: [
        id: [type: :string, required: true],
        topic: [type: :string, required: true],
        source: [type: :string, required: true],
        team_id: [type: :string, required: true],
        tokens: [type: :integer, required: false]
      ]
  end

  defmodule DiscoveryRelevant do
    use Jido.Signal,
      type: "context.discovery.relevant",
      schema: [
        team_id: [type: :string, required: true],
        agent_name: [type: :string, required: true]
      ]
  end
end
