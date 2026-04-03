defmodule Loomkin.Teams.ConsensusPolicy do
  @moduledoc """
  Defines the consensus policy contract for team decisions.

  A policy controls how votes are tallied (quorum mode), how many debate
  rounds are allowed, which expertise scope applies, and what happens
  when no consensus is reached (deadlock strategy).
  """

  @type quorum :: :unanimous | :majority | :supermajority | pos_integer()
  @type deadlock :: :escalate_to_user | :leader_decides | :random_tiebreak
  @type t :: %__MODULE__{
          quorum: quorum(),
          max_rounds: pos_integer(),
          scope: String.t(),
          on_deadlock: deadlock()
        }

  @enforce_keys []
  defstruct quorum: :majority,
            max_rounds: 3,
            scope: "general",
            on_deadlock: :escalate_to_user

  @valid_quorum_atoms ~w(unanimous majority supermajority)a
  @valid_deadlock_atoms ~w(escalate_to_user leader_decides random_tiebreak)a

  @doc """
  Returns the default consensus policy.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Build a policy from a keyword list or map, validating all fields.

  Returns `{:ok, policy}` or `{:error, reasons}` where reasons is a list
  of human-readable error strings.

  ## Examples

      iex> ConsensusPolicy.new(quorum: :majority, max_rounds: 3)
      {:ok, %ConsensusPolicy{quorum: :majority, max_rounds: 3, scope: "general", on_deadlock: :escalate_to_user}}

      iex> ConsensusPolicy.new(quorum: :invalid)
      {:error, ["invalid quorum: :invalid — must be :unanimous, :majority, :supermajority, or a positive integer"]}
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(attrs \\ []) do
    attrs = to_keyword(attrs)

    policy = %__MODULE__{
      quorum: Keyword.get(attrs, :quorum, :majority),
      max_rounds: Keyword.get(attrs, :max_rounds, 3),
      scope: Keyword.get(attrs, :scope, "general"),
      on_deadlock: Keyword.get(attrs, :on_deadlock, :escalate_to_user)
    }

    case validate(policy) do
      [] -> {:ok, policy}
      errors -> {:error, errors}
    end
  end

  @doc """
  Validate a policy struct. Returns a list of error strings (empty = valid).
  """
  @spec validate(t()) :: [String.t()]
  def validate(%__MODULE__{} = p) do
    []
    |> validate_quorum(p.quorum)
    |> validate_max_rounds(p.max_rounds)
    |> validate_scope(p.scope)
    |> validate_deadlock(p.on_deadlock)
    |> Enum.reverse()
  end

  @doc """
  Check whether a vote result meets the quorum threshold.

  ## Parameters
  - `quorum` — the quorum mode from the policy
  - `winning_weight_pct` — the winning option's percentage of total weight (0-100)
  - `total_voters` — number of agents who voted
  - `total_eligible` — number of agents who were eligible to vote
  """
  @spec quorum_met?(quorum(), float(), non_neg_integer(), non_neg_integer()) :: boolean()
  def quorum_met?(:unanimous, pct, total_voters, total_eligible) do
    total_voters > 0 and total_voters == total_eligible and pct >= 100.0
  end

  def quorum_met?(:majority, pct, total_voters, _total_eligible) do
    total_voters > 0 and pct > 50.0
  end

  def quorum_met?(:supermajority, pct, total_voters, _total_eligible) do
    total_voters > 0 and pct >= 66.67
  end

  def quorum_met?(threshold, _pct, total_voters, _total_eligible)
      when is_integer(threshold) and threshold > 0 do
    total_voters >= threshold
  end

  def quorum_met?(_quorum, _pct, _voters, _eligible), do: false

  @doc """
  Build a ConsensusPolicy from a parsed TOML config map (string or atom keys).

  Unknown keys are ignored. Missing keys fall back to defaults.
  Returns `{:ok, policy}` or `{:error, reasons}`.
  """
  @spec from_config(map()) :: {:ok, t()} | {:error, [String.t()]}
  def from_config(config_map) when is_map(config_map) do
    attrs =
      []
      |> maybe_put(:quorum, parse_quorum(config_map))
      |> maybe_put(:max_rounds, get_config_val(config_map, :max_rounds))
      |> maybe_put(:scope, get_config_val(config_map, :scope))
      |> maybe_put(:on_deadlock, parse_deadlock(config_map))

    new(attrs)
  end

  # --- Private helpers ---

  defp to_keyword(attrs) when is_map(attrs) do
    Enum.map(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  rescue
    ArgumentError -> Enum.map(attrs, fn {k, v} -> {safe_to_atom(k), v} end)
  end

  defp to_keyword(attrs) when is_list(attrs), do: attrs

  defp safe_to_atom(k) when is_atom(k), do: k

  defp safe_to_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp validate_quorum(errors, quorum) when quorum in @valid_quorum_atoms, do: errors

  defp validate_quorum(errors, quorum) when is_integer(quorum) and quorum > 0, do: errors

  defp validate_quorum(errors, quorum) do
    [
      "invalid quorum: #{inspect(quorum)} — must be :unanimous, :majority, :supermajority, or a positive integer"
      | errors
    ]
  end

  defp validate_max_rounds(errors, n) when is_integer(n) and n > 0, do: errors

  defp validate_max_rounds(errors, n) do
    ["invalid max_rounds: #{inspect(n)} — must be a positive integer" | errors]
  end

  defp validate_scope(errors, scope) when is_binary(scope) and byte_size(scope) > 0, do: errors

  defp validate_scope(errors, scope) do
    ["invalid scope: #{inspect(scope)} — must be a non-empty string" | errors]
  end

  defp validate_deadlock(errors, d) when d in @valid_deadlock_atoms, do: errors

  defp validate_deadlock(errors, d) do
    [
      "invalid on_deadlock: #{inspect(d)} — must be :escalate_to_user, :leader_decides, or :random_tiebreak"
      | errors
    ]
  end

  defp parse_quorum(config) do
    case get_config_val(config, :quorum) do
      nil -> nil
      val when is_atom(val) -> val
      val when is_integer(val) -> val
      val when is_binary(val) -> quorum_string_to_atom(val)
    end
  end

  defp parse_deadlock(config) do
    case get_config_val(config, :on_deadlock) do
      nil -> nil
      val when is_atom(val) -> val
      val when is_binary(val) -> deadlock_string_to_atom(val)
    end
  end

  defp quorum_string_to_atom("unanimous"), do: :unanimous
  defp quorum_string_to_atom("majority"), do: :majority
  defp quorum_string_to_atom("supermajority"), do: :supermajority

  defp quorum_string_to_atom(other) do
    case Integer.parse(other) do
      {n, ""} when n > 0 -> n
      _ -> other
    end
  end

  defp deadlock_string_to_atom("escalate_to_user"), do: :escalate_to_user
  defp deadlock_string_to_atom("leader_decides"), do: :leader_decides
  defp deadlock_string_to_atom("random_tiebreak"), do: :random_tiebreak
  defp deadlock_string_to_atom(other), do: other

  defp get_config_val(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, val), do: Keyword.put(kw, key, val)
end
