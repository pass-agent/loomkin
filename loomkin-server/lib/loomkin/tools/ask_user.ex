defmodule Loomkin.Tools.AskUser do
  @moduledoc """
  Agent-to-user question tool. When called, publishes a question to the
  mission control UI and blocks until the human (or collective) responds.
  """

  use Jido.Action,
    name: "ask_user",
    description:
      "Ask the human operator a question with selectable options. " <>
        "The question appears in the mission control UI and the agent blocks until " <>
        "the user selects an answer. Use this when you need human input to proceed.",
    schema: [
      question: [type: :string, required: true, doc: "The question to ask the user"],
      options: [type: {:list, :string}, required: true, doc: "List of answer options to present"]
    ]

  import Loomkin.Tool, only: [param!: 2]

  @doc false
  @impl true
  def run(params, context) do
    team_id = param!(context, :team_id)
    question = param!(params, :question)
    options = param!(params, :options)
    agent_name = param!(context, :agent_name)

    question_id = Ecto.UUID.generate()
    caller = self()

    # Register this caller so the answer can be routed back
    Registry.register(Loomkin.Teams.AgentRegistry, {:ask_user, question_id}, caller)

    # Broadcast the question to the team topic so WorkspaceLive picks it up
    signal =
      Loomkin.Signals.Team.AskUserQuestion.new!(%{
        question_id: question_id,
        agent_name: agent_name,
        team_id: team_id,
        question: question
      })

    Loomkin.Signals.publish(%{signal | data: Map.put(signal.data, :options, options)})

    # Block waiting for the answer (up to 5 minutes)
    receive do
      {:ask_user_answer, ^question_id, answer} ->
        # Unregister
        Registry.unregister(Loomkin.Teams.AgentRegistry, {:ask_user, question_id})
        {:ok, %{result: "User answered: #{answer}", answer: answer}}
    after
      300_000 ->
        Registry.unregister(Loomkin.Teams.AgentRegistry, {:ask_user, question_id})
        {:ok, %{result: "Question timed out after 5 minutes. No answer received.", answer: nil}}
    end
  end
end
