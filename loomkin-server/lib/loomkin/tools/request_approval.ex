defmodule Loomkin.Tools.RequestApproval do
  @moduledoc """
  Approval gate tool. When called, publishes an approval request to the mission control UI
  and blocks the agent tool task until a human approves or denies, or the gate times out.

  The agent GenServer keeps running — only the tool task process blocks in the `receive`.
  """

  use Jido.Action,
    name: "request_approval",
    description:
      "Request explicit human approval before proceeding. " <>
        "The agent blocks until a human approves or denies the request in the mission control UI. " <>
        "Use this for irreversible or high-stakes actions that require human sign-off.",
    schema: [
      question: [type: :string, required: true, doc: "The approval question to present"],
      timeout: [
        type: :integer,
        required: false,
        doc: "Timeout in seconds (overrides app default of 300)"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 3]

  @doc false
  @impl true
  def run(params, context) do
    team_id = param!(context, :team_id)
    agent_name = param!(context, :agent_name)
    question = param!(params, :question)

    # Resolve timeout: params[:timeout] in seconds takes priority, then app config
    timeout_ms =
      case param(params, :timeout, nil) do
        nil -> Application.get_env(:loomkin, :approval_gate_timeout_ms, 300_000)
        seconds -> seconds * 1000
      end

    gate_id = Ecto.UUID.generate()

    # Register the tool task process so the approval response can be routed back
    case Registry.register(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id}, self()) do
      {:error, {:already_registered, _}} ->
        {:error, "Approval gate already registered for this agent. Cannot open a second gate."}

      _ ->
        run_gate(gate_id, team_id, agent_name, question, timeout_ms)
    end
  end

  defp run_gate(gate_id, team_id, agent_name, question, timeout_ms) do
    # Publish the approval request signal so LiveView renders the gate UI
    signal =
      Loomkin.Signals.Approval.Requested.new!(%{
        gate_id: gate_id,
        agent_name: agent_name,
        team_id: team_id,
        question: question,
        timeout_ms: timeout_ms
      })

    Loomkin.Signals.publish(signal)

    receive do
      {:approval_response, ^gate_id, decision} ->
        Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})
        format_result(gate_id, agent_name, team_id, decision)
    after
      timeout_ms ->
        Registry.unregister(Loomkin.Teams.AgentRegistry, {:approval_gate, gate_id})

        # Publish resolved signal so LiveView can close the gate UI
        resolved =
          Loomkin.Signals.Approval.Resolved.new!(%{
            gate_id: gate_id,
            agent_name: agent_name,
            team_id: team_id,
            outcome: :timeout
          })

        Loomkin.Signals.publish(resolved)

        {:ok,
         %{
           status: :denied,
           reason: :timeout,
           message:
             "Approval gate timed out after #{div(timeout_ms, 1000)} seconds. No response received.",
           context: nil
         }}
    end
  end

  # -- Private helpers --

  defp format_result(gate_id, agent_name, team_id, %{outcome: :approved, context: ctx}) do
    resolved =
      Loomkin.Signals.Approval.Resolved.new!(%{
        gate_id: gate_id,
        agent_name: agent_name,
        team_id: team_id,
        outcome: :approved
      })

    Loomkin.Signals.publish(resolved)

    {:ok, %{status: :approved, reason: nil, message: "Approved by human.", context: ctx}}
  end

  defp format_result(gate_id, agent_name, team_id, %{
         outcome: :denied,
         reason: reason,
         context: ctx
       }) do
    resolved =
      Loomkin.Signals.Approval.Resolved.new!(%{
        gate_id: gate_id,
        agent_name: agent_name,
        team_id: team_id,
        outcome: :denied
      })

    Loomkin.Signals.publish(resolved)

    {:ok,
     %{
       status: :denied,
       reason: :denied,
       message: reason || "Denied by human.",
       context: ctx
     }}
  end
end
