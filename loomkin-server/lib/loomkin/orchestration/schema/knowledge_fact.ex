defmodule Loomkin.Orchestration.Schema.KnowledgeFact do
  @moduledoc """
  Long-term fact stored in the orchestration knowledge base.

  Bidirectional with the interoperable JSONL knowledge format via
  `Loomkin.Orchestration.Knowledge.Importer` and `Exporter`. Curator-extracted
  facts persist at `:medium` confidence until a human or repeat agreement
  promotes them to `:high`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(pattern gotcha decision anti_pattern codebase_fact api_behavior)a
  @confidences ~w(high medium low)a

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "orchestration_knowledge_facts" do
    field :external_id, :string
    field :type, Ecto.Enum, values: @types
    field :fact, :string
    field :recommendation, :string
    field :confidence, Ecto.Enum, values: @confidences, default: :medium
    field :provenance, {:array, :map}, default: []
    field :tags, {:array, :string}, default: []
    field :affected_files, {:array, :string}, default: []
    field :source_epic_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(id type fact)a
  @optional ~w(external_id recommendation confidence provenance tags affected_files source_epic_id)a

  def changeset(fact, attrs) do
    fact
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:confidence, @confidences)
  end

  def types, do: @types
  def confidences, do: @confidences

  @doc """
  Deterministic signature derived from `type`, normalised `fact` text, and
  sorted lowercased `tags`. Used by curator auto-promotion to detect when the
  same fact has been independently observed across multiple epics.

  Same inputs → same hash. Case- and whitespace-insensitive on `fact`; tag
  order does not matter.
  """
  @spec signature(t() | map()) :: String.t()
  def signature(%__MODULE__{type: type, fact: fact, tags: tags}) do
    do_signature(type, fact, tags)
  end

  def signature(%{type: type, fact: fact} = attrs) do
    do_signature(type, fact, Map.get(attrs, :tags) || Map.get(attrs, "tags") || [])
  end

  defp do_signature(type, fact, tags) when is_binary(fact) do
    type_str =
      case type do
        atom when is_atom(atom) -> Atom.to_string(atom)
        str when is_binary(str) -> str
      end

    normalised_fact =
      fact
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/\s+/, " ")

    sorted_tags =
      (tags || [])
      |> Enum.map(&String.downcase/1)
      |> Enum.sort()

    {type_str, normalised_fact, sorted_tags}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @type t :: %__MODULE__{}
end
