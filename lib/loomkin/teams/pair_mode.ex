defmodule Loomkin.Teams.PairMode do
  @moduledoc """
  Sets up PubSub routing between paired coder + reviewer agents.

  Uses the team's ETS table (via `TableRegistry`) to track active pair sessions.
  Each pair gets a dedicated PubSub topic for real-time event exchange.
  """

  alias Loomkin.Decisions.Graph
  alias Loomkin.Teams.Comms
  alias Loomkin.Teams.TableRegistry

  @type pair_event ::
          :intent_broadcast
          | :file_edited
          | :review_feedback
          | :review_approved
          | :review_rejected

  @type pair_info :: %{
          pair_id: String.t(),
          coder: String.t(),
          reviewer: String.t(),
          started_at: integer(),
          task_opts: map()
        }

  @doc """
  Start a pair programming session between a coder and reviewer.

  Subscribes both agents to a dedicated pair topic and records the session in ETS.

  ## Options

    * `:session_id` - optional session ID for decision graph logging
    * `:description` - optional description of the pairing task

  Returns `{:ok, pair_id}` or `{:error, reason}`.
  """
  @spec start_pair(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def start_pair(team_id, coder_name, reviewer_name, task_opts \\ []) do
    if coder_name == reviewer_name do
      {:error, :same_agent}
    else
      pair_id = Ecto.UUID.generate()

      pair_info = %{
        pair_id: pair_id,
        coder: coder_name,
        reviewer: reviewer_name,
        started_at: System.monotonic_time(:millisecond),
        task_opts: Map.new(task_opts)
      }

      # Store in team ETS table
      table = TableRegistry.get_table!(team_id)
      :ets.insert(table, {{:pair, pair_id}, pair_info})

      # Notify both agents
      Comms.send_to(team_id, coder_name, {:pair_started, pair_id, :coder, reviewer_name})
      Comms.send_to(team_id, reviewer_name, {:pair_started, pair_id, :reviewer, coder_name})

      # Broadcast to team
      Comms.broadcast(team_id, {:pair_session_started, pair_id, coder_name, reviewer_name})

      {:ok, pair_id}
    end
  end

  @doc """
  Stop a pair programming session.

  Cleans up ETS state and unsubscribes from the pair topic.
  """
  @spec stop_pair(String.t(), String.t()) :: :ok | {:error, :not_found}
  def stop_pair(team_id, pair_id) do
    case get_pair(team_id, pair_id) do
      {:ok, pair_info} ->
        table = TableRegistry.get_table!(team_id)
        :ets.delete(table, {:pair, pair_id})

        topic = pair_topic(team_id, pair_id)
        Phoenix.PubSub.unsubscribe(Loomkin.PubSub, topic)

        # Notify both agents
        Comms.send_to(team_id, pair_info.coder, {:pair_stopped, pair_id})
        Comms.send_to(team_id, pair_info.reviewer, {:pair_stopped, pair_id})

        # Broadcast to team
        Comms.broadcast(team_id, {:pair_session_stopped, pair_id})

        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  List all active pair sessions for a team.

  Returns a list of pair info maps.
  """
  @spec list_pairs(String.t()) :: [pair_info()]
  def list_pairs(team_id) do
    table = TableRegistry.get_table!(team_id)

    :ets.match_object(table, {{:pair, :_}, :_})
    |> Enum.map(fn {{:pair, _id}, info} -> info end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Get info for a specific pair session.
  """
  @spec get_pair(String.t(), String.t()) :: {:ok, pair_info()} | :error
  def get_pair(team_id, pair_id) do
    table = TableRegistry.get_table!(team_id)

    case :ets.lookup(table, {:pair, pair_id}) do
      [{{:pair, ^pair_id}, info}] -> {:ok, info}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Broadcast an event on the pair's dedicated topic.

  ## Event types

    * `:intent_broadcast` - coder announces what they intend to do
    * `:file_edited` - coder edited a file
    * `:review_feedback` - reviewer provides feedback
    * `:review_approved` - reviewer approves changes
    * `:review_rejected` - reviewer rejects changes
  """
  @spec broadcast_event(String.t(), String.t(), pair_event(), String.t(), map()) :: :ok
  def broadcast_event(team_id, pair_id, event_type, from, payload \\ %{}) do
    topic = pair_topic(team_id, pair_id)

    message = %{
      event: event_type,
      from: from,
      pair_id: pair_id,
      payload: payload,
      timestamp: System.monotonic_time(:millisecond)
    }

    Phoenix.PubSub.broadcast(Loomkin.PubSub, topic, {:pair_event, message})
  end

  @doc """
  Log review feedback to the decision graph as an observation node.

  Links the feedback to the pair session for traceability.
  """
  @spec log_feedback(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Loomkin.Schemas.DecisionNode.t()} | {:error, term()}
  def log_feedback(team_id, pair_id, reviewer_name, feedback, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    confidence = Keyword.get(opts, :confidence, 50)

    {:ok, node} =
      Graph.add_node(%{
        node_type: :observation,
        title: "Pair review feedback by #{reviewer_name}",
        description: feedback,
        confidence: confidence,
        agent_name: reviewer_name,
        session_id: session_id,
        metadata: %{pair_id: pair_id, team_id: team_id, type: "pair_review"}
      })

    Comms.broadcast_decision(team_id, node.id, reviewer_name)

    {:ok, node}
  end

  # -- Private --

  defp pair_topic(team_id, pair_id) do
    "team:#{team_id}:pair:#{pair_id}"
  end
end
