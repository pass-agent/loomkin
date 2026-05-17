defmodule Loomkin.Orchestration.Workers.Base do
  @moduledoc """
  Shared scaffolding for worker agents (`Researcher`, `Planner`, `Coder`, …).

  A worker is a pure-ish function over its inputs. It builds a chat prompt
  (system = role rubric, user = inputs), calls `Loomkin.Orchestration.LLM`,
  and parses the response.

  Workers are stateless — no GenServer. They run synchronously from inside
  the `IssueOrchestrator` callbacks.

  Concrete worker example:

      defmodule Loomkin.Orchestration.Workers.Researcher do
        use Loomkin.Orchestration.Workers.Base,
          name: :researcher,
          rubric: \"\"\"
          You are the Researcher...
          \"\"\"
      end

      Researcher.call(%{epic: ...})
  """

  alias Loomkin.Orchestration.Knowledge.Primer
  alias Loomkin.Orchestration.LLM
  alias Loomkin.Orchestration.Schema.KnowledgeFact

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    rubric = Keyword.fetch!(opts, :rubric)
    model = Keyword.get(opts, :model)
    parser = Keyword.get(opts, :parser, :raw)

    quote do
      def name, do: unquote(name)
      def rubric, do: unquote(rubric)
      def model, do: unquote(model)

      def call(input, opts \\ []) do
        unquote(__MODULE__).do_call(
          __MODULE__,
          input,
          unquote(parser),
          Keyword.merge([model: unquote(model)], opts)
        )
      end

      defoverridable name: 0, rubric: 0, model: 0, call: 1, call: 2
    end
  end

  @doc false
  def do_call(module, input, parser, opts) do
    {prime_keywords, opts} = Keyword.pop(opts, :prime_keywords, nil)
    {primer_opts, opts} = Keyword.pop(opts, :primer_opts, [])

    user_body =
      input
      |> render_input()
      |> prepend_primed_facts(prime_keywords, primer_opts)

    messages = [
      %{role: :system, content: module.rubric()},
      %{role: :user, content: user_body}
    ]

    llm_opts =
      opts
      |> Keyword.put_new(:reviewer, module.name())
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    with {:ok, text} <- LLM.complete(messages, llm_opts) do
      parse(parser, text)
    end
  end

  # Calls `Primer.prime/1` synchronously and prepends a "## Primed knowledge"
  # section so workers see the top-N relevant facts before their inputs.
  defp prepend_primed_facts(body, nil, _primer_opts), do: body
  defp prepend_primed_facts(body, [], _primer_opts), do: body

  defp prepend_primed_facts(body, keywords, primer_opts) when is_list(keywords) do
    prime_opts =
      primer_opts
      |> Keyword.put(:keywords, keywords)
      |> Keyword.put_new(:limit, 5)

    case safe_prime(prime_opts) do
      [] ->
        body

      facts ->
        section = render_primed_facts(facts)

        cond do
          body == "" or is_nil(body) -> section
          true -> section <> "\n\n" <> body
        end
    end
  end

  defp safe_prime(prime_opts) do
    try do
      Primer.prime(prime_opts)
    rescue
      _ -> []
    catch
      :exit, _ -> []
      :throw, _ -> []
      kind, reason when is_atom(kind) -> handle_unexpected(kind, reason)
    end
  end

  defp handle_unexpected(_kind, _reason), do: []

  @doc """
  Renders a list of `KnowledgeFact` structs into a markdown
  "## Primed knowledge" section (a bullet list of fact + recommendation + tags).
  Pure helper so callers/tests can use it directly.
  """
  @spec render_primed_facts([KnowledgeFact.t()]) :: String.t()
  def render_primed_facts([]), do: ""

  def render_primed_facts(facts) when is_list(facts) do
    bullets = Enum.map_join(facts, "\n", &render_primed_fact/1)
    "## Primed knowledge\n" <> bullets
  end

  defp render_primed_fact(%KnowledgeFact{} = fact) do
    base = "- " <> (fact.fact || "")

    rec =
      case fact.recommendation do
        rec when is_binary(rec) and rec != "" -> " — " <> rec
        _ -> ""
      end

    tags =
      case fact.tags do
        [_ | _] = tags -> " [" <> Enum.join(tags, ", ") <> "]"
        _ -> ""
      end

    base <> rec <> tags
  end

  defp render_primed_fact(fact) when is_map(fact) do
    base = "- " <> (Map.get(fact, :fact) || Map.get(fact, "fact") || "")

    rec =
      case Map.get(fact, :recommendation) || Map.get(fact, "recommendation") do
        rec when is_binary(rec) and rec != "" -> " — " <> rec
        _ -> ""
      end

    tags =
      case Map.get(fact, :tags) || Map.get(fact, "tags") do
        [_ | _] = tags -> " [" <> Enum.join(tags, ", ") <> "]"
        _ -> ""
      end

    base <> rec <> tags
  end

  @doc false
  def render_input(input) when is_binary(input), do: input

  def render_input(input) when is_map(input) do
    {prior, rest} = pop_prior_failures(input)

    body =
      rest
      |> Enum.map_join("\n\n", fn
        {k, v} when is_binary(v) -> "## #{k}\n#{v}"
        {k, v} -> "## #{k}\n#{inspect(v, pretty: true, limit: :infinity)}"
      end)

    case render_prior_failures(prior) do
      nil -> body
      section when body == "" -> section
      section -> section <> "\n\n" <> body
    end
  end

  def render_input(input) when is_list(input),
    do: input |> Enum.map(&render_input/1) |> Enum.join("\n\n")

  # Pull `:prior_failures` (or `"prior_failures"`) out of a map so the rest of
  # the input can be rendered through the regular path while the failures are
  # promoted into a dedicated, highly-visible markdown section the agent reads
  # first.
  defp pop_prior_failures(input) when is_map(input) do
    cond do
      Map.has_key?(input, :prior_failures) ->
        {Map.get(input, :prior_failures), Map.delete(input, :prior_failures)}

      Map.has_key?(input, "prior_failures") ->
        {Map.get(input, "prior_failures"), Map.delete(input, "prior_failures")}

      true ->
        {nil, input}
    end
  end

  defp render_prior_failures(nil), do: nil
  defp render_prior_failures([]), do: nil

  defp render_prior_failures(failures) when is_list(failures) do
    rendered =
      failures
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {failure, idx} ->
        iteration = Map.get(failure, :iteration) || Map.get(failure, "iteration") || idx
        verdicts = Map.get(failure, :verdicts) || Map.get(failure, "verdicts") || []

        "### Attempt #{iteration}\n" <> render_verdicts(verdicts)
      end)

    "## Prior attempts (DO NOT repeat these failures)\n\n" <> rendered
  end

  defp render_verdicts([]), do: "_(no verdicts recorded)_"

  defp render_verdicts(verdicts) when is_list(verdicts) do
    Enum.map_join(verdicts, "\n\n", &render_verdict/1)
  end

  defp render_verdict(verdict) do
    reviewer = Map.get(verdict, :reviewer) || Map.get(verdict, "reviewer") || "reviewer"
    blocking = Map.get(verdict, :blocking) || Map.get(verdict, "blocking") || []
    evidence = Map.get(verdict, :evidence) || Map.get(verdict, "evidence") || []

    blocking_lines =
      if blocking == [], do: "- (none)", else: Enum.map_join(blocking, "\n", &("- " <> &1))

    evidence_lines =
      if evidence == [], do: "- (none)", else: Enum.map_join(evidence, "\n", &("- " <> &1))

    "**#{reviewer}**\n\nBlocking:\n#{blocking_lines}\n\nEvidence:\n#{evidence_lines}"
  end

  defp parse(:raw, text), do: {:ok, text}

  defp parse(:json, text) do
    text |> String.trim() |> strip_code_fences() |> Jason.decode()
  end

  defp parse({:json, key}, text) when is_binary(key) do
    case parse(:json, text) do
      {:ok, map} when is_map(map) -> {:ok, Map.get(map, key)}
      other -> other
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
end
