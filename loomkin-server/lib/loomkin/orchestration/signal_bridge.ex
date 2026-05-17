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
  def handle_info({topic, payload}, state) when topic in @topics do
    publish(topic, payload)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp publish(topic, payload) when is_map(payload) do
    subtype = subtype_from_topic(topic)

    data =
      payload
      |> Map.put(:subtype, subtype)
      |> Map.put_new(:session_id, payload[:session_id])

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
  end

  defp publish(_topic, _other), do: :ok

  defp subtype_from_topic("orchestration.epic"), do: :epic
  defp subtype_from_topic("orchestration.work_unit"), do: :work_unit
  defp subtype_from_topic("orchestration.gate"), do: :gate
  defp subtype_from_topic("orchestration.knowledge"), do: :knowledge
end
