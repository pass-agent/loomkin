defmodule Loomkin.Orchestration.KnowledgeStore do
  @moduledoc """
  GenServer in front of `Loomkin.Orchestration.Schema.KnowledgeFact`.

  Provides a small synchronous API that contexts (and LiveView) call:

    * `put_fact/1` — persist a fact (insert or replace by id)
    * `get_fact/1` — fetch by id
    * `list_facts/1` — filtered list (type, confidence, tags, affected_files)
    * `prime/1` — delegates to `Loomkin.Orchestration.Knowledge.Primer`

  This module deliberately keeps a thin interface so the implementation can be
  swapped (e.g. for tests) without touching call sites.
  """
  use GenServer

  alias Loomkin.Orchestration.Schema.KnowledgeFact
  alias Loomkin.Repo

  import Ecto.Query, only: [from: 2]

  @name __MODULE__

  ## Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Insert or update a fact. Accepts a struct or attribute map. Returns
  `{:ok, fact}` or `{:error, changeset}`.
  """
  @spec put_fact(map() | KnowledgeFact.t(), GenServer.name()) ::
          {:ok, KnowledgeFact.t()} | {:error, Ecto.Changeset.t()}
  def put_fact(attrs, server \\ @name) do
    GenServer.call(server, {:put_fact, attrs})
  end

  @spec get_fact(binary(), GenServer.name()) :: KnowledgeFact.t() | nil
  def get_fact(id, server \\ @name) do
    GenServer.call(server, {:get_fact, id})
  end

  @doc "Lookup a fact by its interoperable external_id."
  @spec get_by_external_id(String.t(), GenServer.name()) :: KnowledgeFact.t() | nil
  def get_by_external_id(external_id, server \\ @name) do
    GenServer.call(server, {:get_by_external_id, external_id})
  end

  @doc """
  List facts. Accepts filters: `type`, `confidence`, `tag`, `affected_file`,
  `source_epic_id`, `limit`, `since`.
  """
  @spec list_facts(map(), GenServer.name()) :: [KnowledgeFact.t()]
  def list_facts(filters \\ %{}, server \\ @name) do
    GenServer.call(server, {:list_facts, filters})
  end

  @doc "Liveness check used by health probes and tests."
  @spec ping(GenServer.name()) :: :pong
  def ping(server \\ @name), do: GenServer.call(server, :ping)

  @doc """
  Return all facts whose `KnowledgeFact.signature/1` matches `signature`.

  Options:

    * `:exclude_epic_id` — omit facts whose `source_epic_id` equals this id
      (used by the Curator to avoid matching a fact against itself).
  """
  @spec find_by_signature(String.t(), keyword(), GenServer.name()) :: [KnowledgeFact.t()]
  def find_by_signature(signature, opts \\ [], server \\ @name)
      when is_binary(signature) do
    GenServer.call(server, {:find_by_signature, signature, opts})
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}

  def handle_call({:put_fact, attrs}, _from, state) do
    {id, attrs} = pop_id(attrs)

    result =
      case Repo.get(KnowledgeFact, id) do
        nil ->
          %KnowledgeFact{}
          |> KnowledgeFact.changeset(Map.put(attrs, :id, id))
          |> Repo.insert()

        existing ->
          existing
          |> KnowledgeFact.changeset(attrs)
          |> Repo.update()
      end

    if match?({:ok, _}, result) do
      {:ok, fact} = result
      broadcast({:fact_added, fact})
    end

    {:reply, result, state}
  end

  def handle_call({:get_fact, id}, _from, state) do
    {:reply, Repo.get(KnowledgeFact, id), state}
  end

  def handle_call({:get_by_external_id, external_id}, _from, state) do
    {:reply, Repo.get_by(KnowledgeFact, external_id: external_id), state}
  end

  def handle_call({:list_facts, filters}, _from, state) do
    {:reply, run_list(filters), state}
  end

  def handle_call({:find_by_signature, signature, opts}, _from, state) do
    exclude = Keyword.get(opts, :exclude_epic_id)

    query =
      case exclude do
        nil ->
          from(f in KnowledgeFact, select: f)

        epic_id ->
          from(f in KnowledgeFact, where: f.source_epic_id != ^epic_id, select: f)
      end

    matches =
      query
      |> Repo.all()
      |> Enum.filter(fn fact -> KnowledgeFact.signature(fact) == signature end)

    {:reply, matches, state}
  end

  ## Internals

  defp pop_id(%KnowledgeFact{id: id} = struct) do
    {id || Ecto.UUID.generate(), Map.from_struct(struct) |> Map.delete(:__meta__)}
  end

  defp pop_id(%{} = attrs) do
    id =
      attrs[:id] || attrs["id"] || Ecto.UUID.generate()

    attrs =
      attrs
      |> Map.drop([:id, "id"])

    {id, attrs}
  end

  defp run_list(filters) do
    base = from(f in KnowledgeFact, order_by: [desc: f.inserted_at])

    base
    |> maybe_filter(:type, filters)
    |> maybe_filter(:confidence, filters)
    |> maybe_filter(:source_epic_id, filters)
    |> maybe_tag_filter(filters)
    |> maybe_affected_file_filter(filters)
    |> maybe_since(filters)
    |> maybe_limit(filters)
    |> Repo.all()
  end

  defp maybe_filter(query, key, filters) do
    case Map.get(filters, key) || Map.get(filters, Atom.to_string(key)) do
      nil -> query
      v -> from(q in query, where: field(q, ^key) == ^v)
    end
  end

  defp maybe_tag_filter(query, %{tag: tag}) when is_binary(tag) do
    from(q in query, where: ^tag in q.tags)
  end

  defp maybe_tag_filter(query, _), do: query

  defp maybe_affected_file_filter(query, %{affected_file: file}) when is_binary(file) do
    from(q in query, where: ^file in q.affected_files)
  end

  defp maybe_affected_file_filter(query, _), do: query

  defp maybe_since(query, %{since: %DateTime{} = ts}) do
    from(q in query, where: q.inserted_at >= ^ts)
  end

  defp maybe_since(query, _), do: query

  defp maybe_limit(query, %{limit: n}) when is_integer(n) and n > 0 do
    from(q in query, limit: ^n)
  end

  defp maybe_limit(query, _), do: query

  defp broadcast(message) do
    case Process.whereis(Loomkin.PubSub) do
      nil -> :ok
      _pid -> Phoenix.PubSub.broadcast(Loomkin.PubSub, "orchestration.knowledge", message)
    end
  rescue
    _ -> :ok
  end
end
