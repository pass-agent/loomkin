defmodule Loomkin.Healing.EphemeralAgentStub do
  @moduledoc "Stub that returns a long-lived dummy process instead of running a real agent loop."

  def start(_opts) do
    # Spawn a process that stays alive until the test ends.
    # The orchestrator monitors it. Normal exit triggers no retry.
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid}
  end

  def tools_for(:diagnostician), do: []
  def tools_for(:fixer), do: []
end
