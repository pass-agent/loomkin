defmodule Loomkin.Signals.Channel do
  @moduledoc "Channel adapter signals: inbound/outbound messages."

  defmodule Message do
    use Jido.Signal,
      type: "channel.message",
      schema: [
        direction: [type: {:in, [:inbound, :outbound]}, required: true],
        channel: [type: :atom, required: true],
        team_id: [type: :string, required: true],
        text: [type: :string, required: false],
        agent_name: [type: :string, required: false]
      ]
  end
end
