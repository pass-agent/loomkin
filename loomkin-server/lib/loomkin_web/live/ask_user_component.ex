defmodule LoomkinWeb.AskUserComponent do
  @moduledoc """
  LiveComponent that renders pending agent-to-user questions in the mission
  control UI. Each question shows the asking agent, the question text, and
  clickable option buttons including a "Let the collective decide" option.
  """

  use LoomkinWeb, :live_component

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-3">
      <div
        :for={q <- @questions}
        class="bg-gradient-to-br from-violet-900/30 to-purple-900/20 border border-violet-500/30 rounded-xl p-4 animate-scale-in shadow-lg shadow-violet-500/10"
        id={"ask-user-#{q.question_id}"}
      >
        <%!-- Header --%>
        <div class="flex items-center gap-2 mb-3">
          <div class="w-8 h-8 rounded-lg bg-violet-500/20 flex items-center justify-center flex-shrink-0">
            <.icon name="hero-question-mark-circle" class="w-4 h-4 text-violet-400" />
          </div>
          <div class="min-w-0">
            <p class="text-xs font-semibold text-violet-300 truncate">
              {q.agent_name} needs your input
            </p>
          </div>
        </div>

        <%!-- Question --%>
        <p class="text-sm text-gray-200 mb-4 leading-relaxed">{q.question}</p>

        <%!-- Option buttons --%>
        <div class="flex flex-wrap gap-2">
          <button
            :for={option <- q.options}
            phx-click="ask_user_answer"
            phx-value-question-id={q.question_id}
            phx-value-answer={option}
            class="px-3 py-1.5 text-xs font-medium text-violet-300 bg-violet-500/10 hover:bg-violet-500/25 border border-violet-500/30 hover:border-violet-400/50 rounded-lg transition-all duration-200 cursor-pointer"
          >
            {option}
          </button>

          <%!-- Always include collective option --%>
          <button
            phx-click="ask_user_answer"
            phx-value-question-id={q.question_id}
            phx-value-answer="__collective__"
            class="px-3 py-1.5 text-xs font-medium text-amber-300 bg-amber-500/10 hover:bg-amber-500/20 border border-amber-500/30 hover:border-amber-400/50 rounded-lg transition-all duration-200 cursor-pointer"
          >
            Let the collective decide
          </button>
        </div>
      </div>
    </div>
    """
  end
end
