defmodule Loomkin.Tools.SpawnConversation do
  @moduledoc "Spawn a group of conversation agents to discuss a topic and return a summary."

  use Jido.Action,
    name: "spawn_conversation",
    description:
      "Spawn a group of conversation agents to discuss a topic and return a summary. " <>
        "Useful for brainstorming, design deliberation, perspective gathering, red-teaming. " <>
        "The conversation runs asynchronously. The summary will appear in the team's collaboration feed. " <>
        "Provide either a list of personas or a template name (brainstorm, design_review, red_team, user_panel).",
    schema: [
      topic: [type: :string, required: true, doc: "What the agents should discuss"],
      personas: [
        type: {:list, :map},
        doc: "List of personas. Each needs: name, perspective, expertise. Min 2, max 6."
      ],
      strategy: [
        type: :string,
        doc: "Turn strategy: round_robin, weighted, or facilitator (default: round_robin)"
      ],
      max_rounds: [
        type: :integer,
        doc: "Maximum conversation rounds (default: 8)"
      ],
      facilitator: [
        type: :string,
        doc: "Name of the facilitator persona (required if strategy is 'facilitator')"
      ],
      context: [
        type: :string,
        doc: "Additional context to provide all participants (code snippets, requirements, etc.)"
      ],
      template: [
        type: :string,
        doc:
          "Use a built-in template instead of manual personas: brainstorm, design_review, red_team, user_panel"
      ]
    ]

  import Loomkin.Tool, only: [param!: 2, param: 2]

  require Logger

  alias Loomkin.Conversations.Agent, as: ConversationAgent
  alias Loomkin.Conversations.Persona
  alias Loomkin.Conversations.Server, as: ConversationServer
  alias Loomkin.Conversations.Templates
  alias Loomkin.Conversations.Weaver

  @min_personas 2
  @default_max_personas 6
  @default_max_rounds 8
  @default_strategy "round_robin"
  @required_persona_fields [
    {:name, "name"},
    {:perspective, "perspective"},
    {:expertise, "expertise"}
  ]
  @valid_strategies ["round_robin", "weighted", "facilitator"]

  @impl true
  def run(params, context) do
    topic = param!(params, :topic)
    template = param(params, :template)

    with {:ok, config} <- resolve_config(template, topic, params),
         {:ok, config} <- apply_overrides(config, params),
         {:ok, config} <- validate_config(config) do
      start_conversation(config, context)
    end
  end

  # When a template is specified, resolve it and use as base config
  defp resolve_config(template, topic, params) when is_binary(template) do
    Templates.get(template, topic, param(params, :context))
  end

  # When no template, build config from params directly
  defp resolve_config(nil, topic, params) do
    personas = param(params, :personas)

    if is_nil(personas) or personas == [] do
      {:error, "Either 'personas' or 'template' must be provided"}
    else
      {:ok,
       %{
         topic: topic,
         context: param(params, :context),
         strategy: strategy_atom(param(params, :strategy) || config_default_strategy()),
         max_rounds: param(params, :max_rounds) || config_default_max_rounds(),
         facilitator: param(params, :facilitator),
         personas: Enum.map(personas, &Persona.from_map/1)
       }}
    end
  end

  # Apply parameter overrides on top of template config
  defp apply_overrides(config, params) do
    config =
      config
      |> maybe_override(:strategy, param(params, :strategy), &strategy_atom/1)
      |> maybe_override(:max_rounds, param(params, :max_rounds))
      |> maybe_override(:facilitator, param(params, :facilitator))

    {:ok, config}
  end

  defp maybe_override(config, _key, nil), do: config
  defp maybe_override(config, key, value), do: Map.put(config, key, value)

  defp maybe_override(config, _key, nil, _transform), do: config
  defp maybe_override(config, key, value, transform), do: Map.put(config, key, transform.(value))

  defp strategy_atom("round_robin"), do: :round_robin
  defp strategy_atom("weighted"), do: :weighted
  defp strategy_atom("facilitator"), do: :facilitator
  defp strategy_atom(atom) when is_atom(atom), do: atom

  defp strategy_atom(other) do
    Logger.warning("[SpawnConversation] Unknown strategy string: #{inspect(other)}")
    other
  end

  defp validate_config(config) do
    with :ok <- validate_personas(config.personas),
         :ok <- validate_strategy(config),
         :ok <- validate_max_rounds(config.max_rounds) do
      {:ok, config}
    end
  end

  defp validate_personas(personas) when length(personas) < @min_personas do
    {:error, "At least #{@min_personas} personas required, got #{length(personas)}"}
  end

  defp validate_personas(personas) do
    max = config_max_personas()

    if length(personas) > max do
      {:error, "At most #{max} personas allowed, got #{length(personas)}"}
    else
      do_validate_persona_fields(personas)
    end
  end

  defp do_validate_persona_fields(personas) do
    missing =
      Enum.flat_map(personas, fn persona ->
        Enum.flat_map(@required_persona_fields, fn {atom_key, str_key} ->
          value = Map.get(persona, atom_key) || Map.get(persona, str_key)

          if is_nil(value) or value == "" do
            name = Map.get(persona, :name) || Map.get(persona, "name") || "unnamed"
            ["#{name} missing #{str_key}"]
          else
            []
          end
        end)
      end)

    if missing == [] do
      :ok
    else
      {:error, "Invalid personas: #{Enum.join(missing, "; ")}"}
    end
  end

  defp validate_strategy(%{strategy: :facilitator, facilitator: nil}) do
    {:error, "Facilitator strategy requires a 'facilitator' parameter"}
  end

  defp validate_strategy(%{strategy: :facilitator, facilitator: facilitator, personas: personas}) do
    names =
      Enum.map(personas, fn
        %Persona{name: name} -> name
        %{name: name} -> name
      end)

    if facilitator in names do
      :ok
    else
      {:error,
       "Facilitator '#{facilitator}' must be one of the persona names: #{Enum.join(names, ", ")}"}
    end
  end

  defp validate_strategy(%{strategy: strategy}) when strategy in [:round_robin, :weighted] do
    :ok
  end

  defp validate_strategy(%{strategy: strategy}) do
    {:error, "Invalid strategy '#{strategy}'. Valid: #{Enum.join(@valid_strategies, ", ")}"}
  end

  defp validate_max_rounds(rounds) when is_integer(rounds) and rounds > 0, do: :ok

  defp validate_max_rounds(rounds),
    do: {:error, "max_rounds must be a positive integer, got #{inspect(rounds)}"}

  defp start_conversation(config, context) do
    team_id = param(context, :team_id) || param(context, :parent_team_id)

    if is_nil(team_id) do
      {:error, "team_id is required but not found in context"}
    else
      do_start_conversation(config, context, team_id)
    end
  end

  defp do_start_conversation(config, context, team_id) do
    session_id = param(context, :session_id)
    spawned_by = param(context, :agent_name) || "unknown"
    model = param(context, :model) || fast_model(session_id)

    conversation_id = Ecto.UUID.generate()
    facilitator_name = Map.get(config, :facilitator)

    # Build participant list with proper structure for ConversationServer
    participants =
      Enum.map(config.personas, fn persona ->
        persona = ensure_persona_struct(persona)
        role = if persona.name == facilitator_name, do: :facilitator, else: :participant

        %{name: persona.name, persona: persona, role: role}
      end)

    conversation_opts = [
      id: conversation_id,
      team_id: team_id,
      topic: config.topic,
      context: Map.get(config, :context),
      spawned_by: spawned_by,
      turn_strategy: config.strategy,
      participants: participants,
      max_rounds: config.max_rounds
    ]

    with {:ok, _server_pid} <- start_server(conversation_opts),
         {:ok, _agent_pids} <- spawn_agents(conversation_id, team_id, config, model),
         :ok <- spawn_weaver(conversation_id, team_id, model, spawned_by),
         :ok <- ConversationServer.begin(conversation_id) do
      participant_names =
        config.personas
        |> Enum.map(fn
          %Persona{name: name} -> name
          %{name: name} -> name
        end)
        |> Enum.join(", ")

      summary =
        "Conversation started (id: #{conversation_id}). " <>
          "Topic: #{config.topic}. " <>
          "Participants: #{participant_names}. " <>
          "Strategy: #{config.strategy}, max #{config.max_rounds} rounds. " <>
          "The summary will appear in the collaboration feed when complete."

      {:ok, %{result: summary, conversation_id: conversation_id}}
    else
      {:error, reason} ->
        # Attempt cleanup of any started processes
        cleanup_conversation(conversation_id)
        {:error, "Failed to start conversation: #{inspect(reason)}"}
    end
  end

  defp ensure_persona_struct(%Persona{} = p), do: p
  defp ensure_persona_struct(map) when is_map(map), do: Persona.from_map(map)

  defp start_server(opts) do
    DynamicSupervisor.start_child(
      Loomkin.Conversations.Supervisor,
      {ConversationServer, opts}
    )
  end

  defp spawn_agents(conversation_id, team_id, config, model) do
    results =
      Enum.map(config.personas, fn persona ->
        persona = ensure_persona_struct(persona)

        agent_opts = [
          conversation_id: conversation_id,
          team_id: team_id,
          persona: persona,
          model: model,
          topic: config.topic
        ]

        DynamicSupervisor.start_child(
          Loomkin.Conversations.Supervisor,
          {ConversationAgent, agent_opts}
        )
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        pids = Enum.map(results, fn {:ok, pid} -> pid end)
        {:ok, pids}

      {:error, reason} ->
        # Terminate already-started agents
        results
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.each(fn {:ok, pid} ->
          DynamicSupervisor.terminate_child(Loomkin.Conversations.Supervisor, pid)
        end)

        {:error, "Failed to spawn agent: #{inspect(reason)}"}
    end
  end

  defp spawn_weaver(conversation_id, team_id, model, spawned_by) do
    weaver_opts = [
      conversation_id: conversation_id,
      team_id: team_id,
      model: model,
      spawned_by: spawned_by
    ]

    case DynamicSupervisor.start_child(
           Loomkin.Conversations.Supervisor,
           {Weaver, weaver_opts}
         ) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, "Failed to spawn weaver: #{inspect(reason)}"}
    end
  end

  defp cleanup_conversation(conversation_id) do
    # Broadcast :summarize to stop any agents/weaver that subscribed
    Phoenix.PubSub.broadcast(
      Loomkin.PubSub,
      "conversation:#{conversation_id}",
      {:summarize, conversation_id, [], "cancelled", []}
    )

    # Terminate the server if it's still running
    case Registry.lookup(Loomkin.Conversations.Registry, conversation_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Loomkin.Conversations.Supervisor, pid)
      [] -> :ok
    end
  end

  defp fast_model(_session_id) do
    Loomkin.Config.get(:model, :fast) || "zai:glm-4.5"
  end

  defp config_max_personas do
    Loomkin.Config.get(:conversations, :max_personas) || @default_max_personas
  end

  defp config_default_max_rounds do
    Loomkin.Config.get(:conversations, :default_max_rounds) || @default_max_rounds
  end

  defp config_default_strategy do
    Loomkin.Config.get(:conversations, :default_strategy) || @default_strategy
  end
end
