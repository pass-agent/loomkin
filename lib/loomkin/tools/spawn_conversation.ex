defmodule Loomkin.Tools.SpawnConversation do
  @moduledoc "Spawn a group of conversation agents to discuss a topic and return a summary."

  use Jido.Action,
    name: "spawn_conversation",
    description:
      "Spawn a group of conversation agents to discuss a topic and return a summary. " <>
        "Useful for brainstorming, design deliberation, perspective gathering, red-teaming. " <>
        "The conversation runs asynchronously. You'll receive a summary when it completes. " <>
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

  alias Loomkin.Conversations.Agent, as: ConversationAgent
  alias Loomkin.Conversations.Persona
  alias Loomkin.Conversations.Server, as: ConversationServer
  alias Loomkin.Conversations.Templates
  alias Loomkin.Conversations.Weaver

  @min_personas 2
  @max_personas 6
  @default_max_rounds 8
  @default_strategy "round_robin"
  @required_persona_fields ["name", "perspective", "expertise"]
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
    context_text = param(params, :context)

    case Templates.get(template, topic, context_text) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
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
         strategy: strategy_atom(param(params, :strategy) || @default_strategy),
         max_rounds: param(params, :max_rounds) || @default_max_rounds,
         facilitator: param(params, :facilitator),
         personas: normalize_personas(personas)
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
  defp strategy_atom(other), do: other

  defp normalize_personas(personas) do
    Enum.map(personas, fn persona ->
      %{
        name: Map.get(persona, :name) || Map.get(persona, "name"),
        perspective: Map.get(persona, :perspective) || Map.get(persona, "perspective"),
        expertise: Map.get(persona, :expertise) || Map.get(persona, "expertise"),
        goal: Map.get(persona, :goal) || Map.get(persona, "goal"),
        personality: Map.get(persona, :personality) || Map.get(persona, "personality"),
        description: Map.get(persona, :description) || Map.get(persona, "description")
      }
    end)
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

  defp validate_personas(personas) when length(personas) > @max_personas do
    {:error, "At most #{@max_personas} personas allowed, got #{length(personas)}"}
  end

  defp validate_personas(personas) do
    missing =
      Enum.flat_map(personas, fn persona ->
        Enum.flat_map(@required_persona_fields, fn field ->
          atom_key = String.to_existing_atom(field)
          value = Map.get(persona, atom_key) || Map.get(persona, field)

          if is_nil(value) or value == "" do
            ["#{persona[:name] || "unnamed"} missing #{field}"]
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
    names = Enum.map(personas, & &1.name)

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
    session_id = param(context, :session_id)
    spawned_by = param(context, :agent_name) || "unknown"
    model = param(context, :model) || fast_model(session_id)

    conversation_id = Ecto.UUID.generate()
    facilitator_name = Map.get(config, :facilitator)

    # Build participant list with proper structure for ConversationServer
    participants =
      Enum.map(config.personas, fn persona_map ->
        persona = Persona.from_map(persona_map)
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
         :ok <- spawn_agents(conversation_id, team_id, config, model),
         :ok <- spawn_weaver(conversation_id, team_id, model, spawned_by) do
      participant_names = Enum.map(config.personas, & &1.name) |> Enum.join(", ")

      summary =
        "Conversation started (id: #{conversation_id}). " <>
          "Topic: #{config.topic}. " <>
          "Participants: #{participant_names}. " <>
          "Strategy: #{config.strategy}, max #{config.max_rounds} rounds. " <>
          "You'll receive a summary when it completes."

      {:ok, %{result: summary, conversation_id: conversation_id}}
    else
      {:error, reason} ->
        {:error, "Failed to start conversation: #{inspect(reason)}"}
    end
  end

  defp start_server(opts) do
    DynamicSupervisor.start_child(
      Loomkin.Conversations.Supervisor,
      {ConversationServer, opts}
    )
  end

  defp spawn_agents(conversation_id, team_id, config, model) do
    results =
      Enum.map(config.personas, fn persona_map ->
        persona = Persona.from_map(persona_map)

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
      nil -> :ok
      {:error, reason} -> {:error, "Failed to spawn agent: #{inspect(reason)}"}
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

  defp fast_model(_session_id) do
    if Code.ensure_loaded?(Loomkin.Config) do
      try do
        Loomkin.Config.get(:model, :fast) || "zai:glm-4.5"
      rescue
        _ -> "zai:glm-4.5"
      end
    else
      "zai:glm-4.5"
    end
  end
end
