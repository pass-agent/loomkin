defmodule Loomkin.Orchestration.Pipelines.LitePipeline do
  @moduledoc """
  The degenerate "fast chat" pipeline.

  Spawns or reuses a `Loomkin.Teams.Agent` (the team's `"concierge"`) and
  forwards the user message via `Loomkin.Teams.Agent.send_message/2`. The
  agent's streaming signals (`agent.stream.delta`, `agent.stream.end`,
  `session.message.new`, `session.status.changed`) are emitted inside that
  call, so the streaming contract is preserved byte-for-byte — this module
  contributes no new wire events of its own.

  When the session has no `:team_id` (e.g. before bootstrap), the pipeline
  returns `{:error, :no_team}` so `SessionBridge` can convert that to
  `{:legacy, _}` and the legacy concierge code path runs one more time.

  Contract:

      run(session_state :: map(), message :: String.t(), opts :: keyword()) ::
        {:ok, response :: String.t()}
        | {:legacy, reason :: String.t()}
        | {:error, term()}
  """

  require Logger

  alias Loomkin.Session.Manager, as: SessionManager
  alias Loomkin.Teams.Agent, as: TeamsAgent

  @default_agent_name "concierge"

  @spec run(map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:legacy, String.t()} | {:error, term()}
  def run(session_state, message, opts \\ []) when is_map(session_state) do
    agent_name = Keyword.get(opts, :target_agent) || @default_agent_name

    with team_id when is_binary(team_id) <- Map.get(session_state, :team_id) || :no_team,
         {:ok, pid} <- find_or_error(team_id, agent_name) do
      case TeamsAgent.send_message(pid, message) do
        {:ok, response} when is_binary(response) ->
          {:ok, response}

        {:error, reason} ->
          Logger.warning("[lite_pipeline] agent #{agent_name} returned error: #{inspect(reason)}")

          {:error, reason}

        other ->
          Logger.warning(
            "[lite_pipeline] agent #{agent_name} returned unexpected reply: #{inspect(other)}"
          )

          {:error, {:unexpected_reply, other}}
      end
    else
      :no_team -> {:error, :no_team}
      :error -> {:error, {:agent_not_found, agent_name}}
      {:error, _} = err -> err
    end
  end

  defp find_or_error(team_id, agent_name) do
    case SessionManager.find_agent(team_id, agent_name) do
      {:ok, pid} -> {:ok, pid}
      :error -> :error
    end
  end
end
