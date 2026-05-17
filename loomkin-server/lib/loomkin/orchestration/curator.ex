defmodule Loomkin.Orchestration.Curator do
  @moduledoc """
  Post-task knowledge extraction.

  Subscribes to `orchestration.work_unit` events; on a `:completed` event,
  asks an LLM to extract patterns/gotchas/decisions from the work unit's
  trace and persists each fact at `:medium` confidence.

  The Curator never writes `:high` confidence on its own — promotion
  requires either a human flag or repeat detection across epics.

  Callable directly via `extract/2` for in-process tests.
  """
  use GenServer

  alias Loomkin.Orchestration.KnowledgeStore
  alias Loomkin.Orchestration.LLM
  alias Loomkin.Orchestration.Schema.KnowledgeFact

  @topic "orchestration.work_unit"

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Extract knowledge facts from a single completed work unit synchronously.
  Returns `{:ok, [%KnowledgeFact{}]}` on success.

  Options:

    * `:store` — KnowledgeStore name to persist into
    * `:llm_opts` — opts forwarded to `LLM.complete/2`
  """
  @spec extract(map(), keyword()) :: {:ok, [KnowledgeFact.t()]} | {:error, term()}
  def extract(work_unit_summary, opts \\ []) when is_map(work_unit_summary) do
    store = Keyword.get(opts, :store, KnowledgeStore)

    messages = [
      %{role: :system, content: curator_prompt()},
      %{role: :user, content: render(work_unit_summary)}
    ]

    llm_opts = Keyword.get(opts, :llm_opts, []) |> Keyword.put_new(:reviewer, :knowledge_curator)

    with {:ok, text} <- LLM.complete(messages, llm_opts),
         {:ok, decoded} <- decode(text),
         {:ok, persisted} <- persist(decoded, store, work_unit_summary) do
      {:ok, persisted}
    end
  end

  defp curator_prompt do
    """
    You are the Knowledge Curator. Read the work-unit summary the user supplies
    and extract reusable knowledge as a strict JSON array. Each item:

      {
        "type": "pattern" | "gotcha" | "decision" | "anti_pattern" |
                "codebase_fact" | "api_behavior",
        "fact": "short description",
        "recommendation": "what to do",
        "tags": ["one", "or-more"],
        "affected_files": ["path", ...]
      }

    Confidence is always set by the framework to "medium" — do not set it.

    Return ONLY the JSON array. Empty array is acceptable if nothing learned.
    """
  end

  defp render(summary) do
    summary
    |> Enum.map_join("\n\n", fn
      {k, v} when is_binary(v) -> "## #{k}\n#{v}"
      {k, v} -> "## #{k}\n#{inspect(v, pretty: true, limit: :infinity)}"
    end)
  end

  defp decode(text) do
    text
    |> String.trim()
    |> strip_code_fences()
    |> Jason.decode()
    |> case do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, {:not_a_list, other}}
      {:error, _} = err -> err
    end
  end

  defp strip_code_fences(text) do
    cond do
      String.starts_with?(text, "```json") ->
        text
        |> String.replace_prefix("```json", "")
        |> String.trim()
        |> String.replace_suffix("```", "")
        |> String.trim()

      String.starts_with?(text, "```") ->
        text
        |> String.replace_prefix("```", "")
        |> String.trim()
        |> String.replace_suffix("```", "")
        |> String.trim()

      true ->
        text
    end
  end

  defp persist(facts, store, summary) do
    epic_id = Map.get(summary, :epic_id) || Map.get(summary, "epic_id")

    persisted =
      Enum.flat_map(facts, fn raw ->
        attrs = %{
          id: raw["id"] || Ecto.UUID.generate(),
          type: parse_type(raw["type"]),
          fact: raw["fact"],
          recommendation: raw["recommendation"],
          confidence: :medium,
          tags: raw["tags"] || [],
          affected_files: raw["affected_files"] || raw["affectedFiles"] || [],
          provenance: [
            %{
              "source" => "agent",
              "reference" =>
                "curator:work_unit:#{Map.get(summary, :work_unit_id) || Map.get(summary, "work_unit_id")}"
            }
          ],
          source_epic_id: epic_id
        }

        case KnowledgeStore.put_fact(attrs, store) do
          {:ok, fact} -> [maybe_auto_promote(fact, store, epic_id)]
          {:error, _} -> []
        end
      end)

    {:ok, persisted}
  end

  # When the just-persisted fact shares a signature with any fact from a
  # DIFFERENT epic, promote both to :high. Returns the (possibly updated) fact.
  defp maybe_auto_promote(%KnowledgeFact{} = fact, store, epic_id) do
    signature = KnowledgeFact.signature(fact)

    matches =
      KnowledgeStore.find_by_signature(signature, [exclude_epic_id: epic_id], store)
      |> Enum.reject(&(&1.id == fact.id))

    case matches do
      [] ->
        fact

      _ ->
        promoted_self =
          case KnowledgeStore.put_fact(
                 %{id: fact.id, type: fact.type, fact: fact.fact, confidence: :high},
                 store
               ) do
            {:ok, updated} -> updated
            _ -> %{fact | confidence: :high}
          end

        promoted_ids =
          Enum.reduce(matches, [promoted_self.id], fn match, acc ->
            case KnowledgeStore.put_fact(
                   %{id: match.id, type: match.type, fact: match.fact, confidence: :high},
                   store
                 ) do
              {:ok, updated} -> [updated.id | acc]
              _ -> acc
            end
          end)

        broadcast_promotion(promoted_ids)
        promoted_self
    end
  end

  defp broadcast_promotion(fact_ids) do
    case Process.whereis(Loomkin.PubSub) do
      nil ->
        :ok

      _pid ->
        Phoenix.PubSub.broadcast(
          Loomkin.PubSub,
          "orchestration.knowledge",
          {:promoted, fact_ids}
        )
    end
  rescue
    _ -> :ok
  end

  defp parse_type(t) when is_binary(t), do: String.to_atom(String.replace(t, "-", "_"))
  defp parse_type(t) when is_atom(t), do: t
  defp parse_type(_), do: :codebase_fact

  ## GenServer callbacks

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, KnowledgeStore)

    # Auto-subscription is OFF by default so the orchestrator's :closure
    # callback remains the single, deterministic trigger for extraction.
    # Set `auto_subscribe: true` to also extract on every work-unit completion
    # (e.g. for continuous-learning experiments).
    if Keyword.get(opts, :auto_subscribe, false) && Process.whereis(Loomkin.PubSub) do
      Phoenix.PubSub.subscribe(Loomkin.PubSub, @topic)
    end

    {:ok, %{store: store}}
  end

  @impl true
  def handle_info({@topic, %{event: :completed} = msg}, state) do
    summary = Map.put(msg, :artifact, Map.get(msg, :artifact))
    _ = extract(summary, store: state.store)
    {:noreply, state}
  end

  def handle_info({@topic, _other}, state), do: {:noreply, state}
end
