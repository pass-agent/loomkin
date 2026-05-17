defmodule Loomkin.Orchestration.SignalBridge do
  @moduledoc """
  Subscribes to the orchestration framework's `Phoenix.PubSub` topics and
  republishes the events as `Jido.Signal` messages on `Loomkin.SignalBus` so
  the existing session channel + LiveView surfaces pick them up without
  changing the streaming contract.

  Topic mapping:

      orchestration.epic       → signal type "session.orchestration.phase" with subtype "epic"
      orchestration.work_unit  → signal type "session.orchestration.phase" with subtype "work_unit"
      orchestration.gate       → signal type "session.orchestration.phase" with subtype "gate"
      orchestration.knowledge  → signal type "session.orchestration.phase" with subtype "knowledge"

  In addition to the phase events above, the `orchestration.work_unit` topic
  also carries diff events emitted by `WorkUnitPipeline` after a successful
  commit. Those are republished as `"session.orchestration.diff"` signals so
  the CLI / LiveView can render an inline diff summary alongside the phase
  feed without changing the existing streaming contract.

  Signal payload shape:

      %Jido.Signal{
        type: "session.orchestration.phase",
        data: %{
          subtype: :epic | :work_unit | :gate | :knowledge,
          event: term(),
          epic_id: binary() | nil,
          work_unit_id: binary() | nil,
          session_id: binary() | nil
        }
      }

  Sessions filter by `session_id` (which the IssueOrchestrator stamps into
  epic metadata when created via `SessionBridge.submit_complex_task/3`).
  """
  use GenServer

  @topics ~w(orchestration.epic orchestration.work_unit orchestration.gate orchestration.knowledge)

  ## Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  ## Callbacks

  @impl true
  def init(_opts) do
    case Process.whereis(Loomkin.PubSub) do
      nil -> :ok
      _pid -> Enum.each(@topics, &Phoenix.PubSub.subscribe(Loomkin.PubSub, &1))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({topic, %{event: :diff} = payload}, state)
      when topic == "orchestration.work_unit" do
    publish_diff(payload)
    {:noreply, state}
  end

  def handle_info({topic, payload}, state) when topic in @topics do
    publish(topic, payload)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp publish(topic, payload) when is_map(payload) do
    subtype = subtype_from_topic(topic)
    persona = Loomkin.Orchestration.Personas.for_event(subtype, payload)

    data =
      payload
      |> Map.put(:subtype, subtype)
      |> Map.put_new(:session_id, payload[:session_id])
      |> Map.put(:persona, persona)

    signal = %Jido.Signal{
      id: Ecto.UUID.generate(),
      source: "loomkin.orchestration",
      type: "session.orchestration.phase",
      datacontenttype: "application/json",
      time: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data,
      specversion: "1.0.2"
    }

    try do
      Loomkin.Signals.publish(signal)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # Piggy-back: every epic-level event is a good moment to refresh the
    # client-side cost + ETA bands. The compute is cheap (two indexed
    # queries) and the signal is dropped when no epic_id is in the payload.
    if subtype == :epic, do: publish_cost_update(payload)
  end

  defp publish(_topic, _other), do: :ok

  defp publish_cost_update(%{epic_id: epic_id} = payload) when is_binary(epic_id) do
    cost = safe_cost(epic_id)
    eta_ms = safe_eta(epic_id, payload[:current_phase] || payload[:phase])

    data = %{
      epic_id: epic_id,
      session_id: payload[:session_id],
      cost_usd: cost_to_float(cost),
      eta_seconds: ms_to_seconds(eta_ms)
    }

    signal = %Jido.Signal{
      id: Ecto.UUID.generate(),
      source: "loomkin.orchestration",
      type: "session.orchestration.cost",
      datacontenttype: "application/json",
      time: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data,
      specversion: "1.0.2"
    }

    try do
      Loomkin.Signals.publish(signal)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp publish_cost_update(_), do: :ok

  defp safe_cost(epic_id) do
    Loomkin.Orchestration.Metrics.cost_for_epic(epic_id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp safe_eta(epic_id, phase) do
    Loomkin.Orchestration.Metrics.eta_for_epic(epic_id, phase)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp cost_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp cost_to_float(_), do: nil

  defp ms_to_seconds(ms) when is_integer(ms) and ms >= 0, do: div(ms, 1_000)
  defp ms_to_seconds(_), do: nil

  defp publish_diff(payload) when is_map(payload) do
    data = %{
      subtype: :work_unit,
      work_unit_id: payload[:work_unit_id],
      sha: payload[:sha],
      stats: payload[:stats] || %{additions: 0, deletions: 0, files: 0},
      files: payload[:files] || [],
      patch_excerpt: payload[:patch_excerpt] || "",
      session_id: payload[:session_id]
    }

    signal = %Jido.Signal{
      id: Ecto.UUID.generate(),
      source: "loomkin.orchestration",
      type: "session.orchestration.diff",
      datacontenttype: "application/json",
      time: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: data,
      specversion: "1.0.2"
    }

    try do
      Loomkin.Signals.publish(signal)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp subtype_from_topic("orchestration.epic"), do: :epic
  defp subtype_from_topic("orchestration.work_unit"), do: :work_unit
  defp subtype_from_topic("orchestration.gate"), do: :gate
  defp subtype_from_topic("orchestration.knowledge"), do: :knowledge
end
