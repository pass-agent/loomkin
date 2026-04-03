defmodule Loomkin.Channels.Router do
  @moduledoc """
  Central coordinator for channel inbound events.

  Receives inbound messages from adapters, resolves bindings,
  parses bot commands, and dispatches to Bridge processes.
  """

  alias Loomkin.Channels.AuditLog
  alias Loomkin.Channels.Bindings
  alias Loomkin.Channels.Bridge
  alias Loomkin.Channels.BridgeSupervisor

  @adapters %{
    telegram: Loomkin.Channels.Telegram.Adapter,
    discord: Loomkin.Channels.Discord.Adapter
  }

  @doc """
  Handle an inbound event from a channel adapter.

  Parses the event via the adapter, checks for bot commands, and
  routes regular messages to the appropriate Bridge.

  Enforces ACL checks:
  - Chat/channel ID must be in `allowed_chat_ids` (Telegram) or `guild_ids` (Discord) if configured
  - User ID must be in `allow_user_ids` if configured
  """
  @spec handle_inbound(module(), atom(), String.t(), term()) ::
          {:ok, term()} | {:error, term()}
  def handle_inbound(adapter, channel, channel_id, raw_event) do
    with :ok <- check_channel_acl(channel, channel_id) do
      case adapter.parse_inbound(raw_event) do
        {:message, text, metadata} ->
          with :ok <- check_user_acl(channel, metadata) do
            case parse_command(text) do
              {:command, cmd, args} ->
                result = handle_command(cmd, args, channel, channel_id, metadata)
                audit_command(channel, channel_id, metadata, cmd, args, result)
                result

              :not_command ->
                route_message(channel, channel_id, raw_event, adapter)
            end
          end

        {:callback, callback_id, data} ->
          callback_metadata = if is_map(data), do: data, else: %{}

          with :ok <- check_user_acl(channel, callback_metadata) do
            handle_callback(channel, channel_id, callback_id, data)
          end

        :ignore ->
          {:ok, :ignored}
      end
    end
  end

  @doc "Route a button/keyboard callback to the appropriate bridge."
  @spec handle_callback(atom(), String.t(), String.t(), term()) ::
          {:ok, term()} | {:error, term()}
  def handle_callback(channel, channel_id, callback_id, data) do
    case Bridge.handle_callback(channel, channel_id, callback_id, data) do
      :ok -> {:ok, :callback_routed}
      {:error, :no_bridge} -> {:error, :no_binding}
    end
  end

  # --- Bot Commands ---

  @doc false
  def parse_command("/" <> rest) do
    case String.split(rest, ~r/\s+/, parts: 2) do
      [cmd] -> {:command, cmd, ""}
      [cmd, args] -> {:command, cmd, args}
    end
  end

  def parse_command(_), do: :not_command

  defp handle_command("bind", args, channel, channel_id, _metadata) do
    team_id = String.trim(args)

    if team_id == "" do
      {:ok, "Usage: /bind <team_id>"}
    else
      case Bindings.find_or_create(channel, channel_id, team_id) do
        {:ok, binding} ->
          ensure_bridge(binding, adapter_for(channel))
          {:ok, "Bound to team #{team_id}."}

        {:error, changeset} ->
          {:error, "Failed to bind: #{inspect(changeset.errors)}"}
      end
    end
  end

  defp handle_command("unbind", _args, channel, channel_id, _metadata) do
    case Bindings.get_by_channel(channel, channel_id) do
      nil ->
        {:ok, "No active binding found."}

      binding ->
        BridgeSupervisor.stop_bridge(channel, channel_id)
        Bindings.deactivate_binding(binding)
        {:ok, "Unbound from team #{binding.team_id}."}
    end
  end

  defp handle_command("status", _args, channel, channel_id, _metadata) do
    case Bindings.get_by_channel(channel, channel_id) do
      nil ->
        {:ok, "No active binding. Use /bind <team_id> to connect."}

      binding ->
        agents = Loomkin.Teams.Manager.list_agents(binding.team_id)

        agent_lines =
          Enum.map(agents, fn {name, pid} ->
            status = if Process.alive?(pid), do: "active", else: "stopped"
            "  - #{name} (#{status})"
          end)

        summary =
          ["Team: #{binding.team_id}", "Agents (#{length(agents)}):"] ++ agent_lines

        {:ok, Enum.join(summary, "\n")}
    end
  end

  defp handle_command("agents", _args, channel, channel_id, _metadata) do
    case Bindings.get_by_channel(channel, channel_id) do
      nil ->
        {:ok, "No active binding. Use /bind <team_id> to connect."}

      binding ->
        agents = Loomkin.Teams.Manager.list_agents(binding.team_id)

        if agents == [] do
          {:ok, "No agents active in team #{binding.team_id}."}
        else
          lines = Enum.map(agents, fn {name, _pid} -> "  - #{name}" end)
          {:ok, "Agents:\n" <> Enum.join(lines, "\n")}
        end
    end
  end

  defp handle_command("ask", args, channel, channel_id, _metadata) do
    case Bindings.get_by_channel(channel, channel_id) do
      nil ->
        {:ok, "No active binding. Use /bind <team_id> to connect."}

      binding ->
        case String.split(args, ~r/\s+/, parts: 2) do
          [agent_name, message] ->
            team_id = binding.team_id

            case Registry.lookup(Loomkin.Teams.AgentRegistry, {team_id, agent_name}) do
              [{pid, _}] ->
                Loomkin.Teams.Agent.send_message(pid, message)
                {:ok, "Message sent to #{agent_name}."}

              [] ->
                {:ok, "Agent '#{agent_name}' not found in team #{team_id}."}
            end

          _ ->
            {:ok, "Usage: /ask <agent_name> <message>"}
        end
    end
  end

  defp handle_command("cancel", args, _channel, _channel_id, _metadata) do
    session_id = String.trim(args)

    if session_id == "" do
      {:ok, "Usage: /cancel <session_id>"}
    else
      case Loomkin.Session.cancel(session_id) do
        :ok ->
          {:ok, "Session #{session_id} cancelled."}

        {:error, :not_found} ->
          {:ok, "Session '#{session_id}' not found."}

        {:error, reason} ->
          {:ok, "Failed to cancel: #{inspect(reason)}"}
      end
    end
  end

  defp handle_command("send", args, _channel, _channel_id, _metadata) do
    case String.split(args, ~r/\s+/, parts: 2) do
      [session_id, text] ->
        case Loomkin.Session.send_message(session_id, text) do
          {:ok, _response} ->
            {:ok, "Message sent to session #{session_id}."}

          {:error, :not_found} ->
            {:ok, "Session '#{session_id}' not found."}

          {:error, reason} ->
            {:ok, "Failed to send: #{inspect(reason)}"}
        end

      _ ->
        {:ok, "Usage: /send <session_id> <text>"}
    end
  end

  defp handle_command("cost", args, channel, channel_id, _metadata) do
    team_id =
      case String.trim(args) do
        "" ->
          case Bindings.get_by_channel(channel, channel_id) do
            nil -> nil
            binding -> binding.team_id
          end

        id ->
          id
      end

    if team_id do
      usage = Loomkin.Teams.CostTracker.get_team_usage(team_id)

      if usage == %{} do
        {:ok, "No usage data for team #{team_id}."}
      else
        lines =
          Enum.map(usage, fn {agent, stats} ->
            cost = Float.round(stats.cost || 0.0, 4)
            tokens = (stats.input_tokens || 0) + (stats.output_tokens || 0)
            "  - #{agent}: $#{cost} (#{tokens} tokens, #{stats.requests || 0} requests)"
          end)

        total_cost =
          usage
          |> Map.values()
          |> Enum.reduce(0.0, fn s, acc -> acc + (s.cost || 0.0) end)
          |> Float.round(4)

        header = "Cost for team #{team_id} (total: $#{total_cost}):"
        {:ok, Enum.join([header | lines], "\n")}
      end
    else
      {:ok, "No active binding. Use /cost <team_id> or /bind first."}
    end
  end

  defp handle_command("perm", args, channel, channel_id, _metadata) do
    alias Loomkin.Channels.PermissionRegistry

    team_id =
      case String.trim(args) do
        "" ->
          case Bindings.get_by_channel(channel, channel_id) do
            nil -> nil
            binding -> binding.team_id
          end

        id ->
          id
      end

    pending = PermissionRegistry.list_pending(team_id)

    if pending == [] do
      {:ok, "No pending permission requests."}
    else
      lines =
        Enum.map(pending, fn req ->
          "  [#{req.request_id}] #{req.agent_name} wants #{req.tool_name} on #{req.tool_path} (#{req.age_seconds}s ago)"
        end)

      {:ok, "Pending permissions (#{length(pending)}):\n" <> Enum.join(lines, "\n")}
    end
  end

  defp handle_command("approve", args, _channel, _channel_id, _metadata) do
    alias Loomkin.Channels.PermissionRegistry

    case String.split(String.trim(args), ~r/\s+/, parts: 2) do
      [request_id, action] when action in ["once", "always", "deny"] ->
        case PermissionRegistry.resolve_request(request_id, action) do
          :ok ->
            {:ok, "Permission #{request_id} resolved: #{action}."}

          {:error, :not_found} ->
            {:ok, "Request '#{request_id}' not found or agent no longer active."}

          {:error, :expired} ->
            {:ok, "Request '#{request_id}' has expired."}
        end

      [_request_id] ->
        {:ok, "Usage: /approve <request_id> once|always|deny"}

      _ ->
        {:ok, "Usage: /approve <request_id> once|always|deny"}
    end
  end

  defp handle_command("audit", args, _channel, _channel_id, _metadata) do
    limit =
      case Integer.parse(String.trim(args)) do
        {n, _} when n > 0 -> min(n, 50)
        _ -> 10
      end

    {:ok, AuditLog.format_recent(limit)}
  end

  defp handle_command(cmd, _args, _channel, _channel_id, _metadata) do
    {:ok,
     "Unknown command: /#{cmd}. Available: /bind, /unbind, /status, /agents, /ask, /cancel, /send, /cost, /perm, /approve, /audit"}
  end

  # --- ACL Checks ---

  @doc false
  def check_channel_acl(channel, channel_id) do
    allowed = channel_allowed_ids(channel)

    if allowed == [] or to_string(channel_id) in Enum.map(allowed, &to_string/1) do
      :ok
    else
      {:error, :channel_not_allowed}
    end
  end

  @doc false
  def check_user_acl(channel, metadata) do
    allowed = user_allowed_ids(channel)
    user_id = extract_user_id(channel, metadata)

    cond do
      allowed == [] ->
        :ok

      is_nil(user_id) ->
        # No user ID in metadata — allow through (adapter doesn't provide it)
        :ok

      to_string(user_id) in Enum.map(allowed, &to_string/1) ->
        :ok

      true ->
        {:error, :user_not_allowed}
    end
  end

  defp channel_allowed_ids(:telegram) do
    case Loomkin.Config.get(:channels) do
      %{telegram: %{allowed_chat_ids: ids}} when is_list(ids) -> ids
      _ -> []
    end
  end

  defp channel_allowed_ids(:discord) do
    case Loomkin.Config.get(:channels) do
      %{discord: %{guild_ids: ids}} when is_list(ids) -> ids
      _ -> []
    end
  end

  defp channel_allowed_ids(_), do: []

  defp user_allowed_ids(channel) do
    case Loomkin.Config.get(:channels) do
      %{^channel => %{allow_user_ids: ids}} when is_list(ids) -> ids
      _ -> []
    end
  end

  defp extract_user_id(:telegram, metadata), do: Map.get(metadata, :from_id)
  defp extract_user_id(:discord, metadata), do: Map.get(metadata, :user_id)
  defp extract_user_id(_, _metadata), do: nil

  # --- Audit ---

  defp audit_command(channel, channel_id, metadata, command, args, result) do
    {status, response} =
      case result do
        {:ok, text} when is_binary(text) -> {:ok, text}
        {:ok, _} -> {:ok, nil}
        {:error, reason} -> {:error, inspect(reason)}
      end

    AuditLog.log_command(channel, channel_id, metadata, command, args, status, response)
  end

  # --- Private ---

  defp route_message(channel, channel_id, raw_event, adapter) do
    case Bridge.lookup(channel, channel_id) do
      {:ok, _pid} ->
        Bridge.handle_inbound(channel, channel_id, raw_event)
        {:ok, :routed}

      :error ->
        # Try to find a binding and start a bridge
        case Bindings.get_by_channel(channel, channel_id) do
          nil ->
            {:error, :no_binding}

          binding ->
            case ensure_bridge(binding, adapter) do
              {:ok, _pid} ->
                Bridge.handle_inbound(channel, channel_id, raw_event)
                {:ok, :routed}

              error ->
                error
            end
        end
    end
  end

  defp ensure_bridge(binding, adapter) do
    case Bridge.lookup(binding.channel, binding.channel_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> BridgeSupervisor.start_bridge(binding, adapter)
    end
  end

  @doc false
  def adapter_for(channel), do: Map.fetch!(@adapters, channel)
end
