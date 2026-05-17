defmodule Loomkin.Orchestration.PRShepherd.Supervisor do
  @moduledoc """
  DynamicSupervisor that owns the per-PR `PRShepherd.Server` processes.

  Started under `Loomkin.Orchestration.Supervisor`. Spawn a shepherd via
  `shepherd/2`:

      iex> Loomkin.Orchestration.PRShepherd.Supervisor.shepherd({"owner", "repo", 42},
      ...>   epic_id: "epic-1")
      {:ok, #PID<...>}
  """
  use DynamicSupervisor

  alias Loomkin.Orchestration.PRShepherd.Server

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Spawn a shepherd for the given PR. If one is already registered for this
  `pr_ref` the existing pid is returned wrapped in `{:ok, pid}`.

  Opts are forwarded to `Server.start_link/1`. Supported keys: `:epic_id`,
  `:github_client`, `:poll_interval_ms`.
  """
  def shepherd({_, _, _} = pr_ref, opts \\ []) do
    case Server.whereis(pr_ref) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        DynamicSupervisor.start_child(
          __MODULE__,
          {Server, Keyword.put(opts, :pr_ref, pr_ref)}
        )
    end
  end
end
